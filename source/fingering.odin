package app

/*
    Tracking (the Helper): where on the fingerboard each note of the layer is
    played, and the path the hand takes from one to the next.

    Every note of the active layer is given a place on the board - a string,
    and how far up it - one after another from the start of the layer, each
    chosen from where the previous one was:

      Same string   stay on the string you are on if it can play the note;
                    only when it cannot, go to the nearest place that can.
      Nearest       whichever place for the note is physically closest to the
                    last one, whatever string it is on.

    The first note goes wherever it sits lowest on the neck.

    "Physically closest" is measured on the real instrument, not on the
    drawing, from its instrument file's board_mm: a full-size cello's strings
    are 695 mm long, nut to bridge, 23 mm apart outer to outer at the nut and
    47 mm at the bridge (from a luthier's measurement chart); semitone n is
    stopped 695 * (1 - 2^(-n/12)) mm from the nut. From that, the distance
    between every pair of places on the board is worked out once per board
    (fb_dist).

    The fingerboard then draws the last N notes up to the playhead (or up to
    the selected note, when stopped): each note filled with its own colour -
    the colours cycle, note by note - and the way from one to the next along
    the string (the string coloured, blending from
    one note's colour into the next's), or, from string to string, an arrow
    straight across the board.
*/

import "core:fmt"
import "core:math"
import "music"
import rl "vendor:raylib"

Track_Mode :: enum u8 {
	Same_String,
	Nearest,
	Best,
}

TRACK_MODE_NAME := [Track_Mode]string {
	.Same_String = "Same string",
	.Nearest     = "Nearest",
	.Best        = "Best",
}

// Room for a trail: every step can be a chord across all the strings.
TRAIL_CAP :: TRACK_MAX * music.BOARD_MAX_STRINGS

TRACK_DEFAULT_N :: 8
TRACK_MAX :: 64

// The colours the notes cycle through: bright, and each unlike the next.
TRACK_COLOURS := [?]rl.Color {
	{255, 90, 90, 255},
	{255, 170, 60, 255},
	{250, 230, 70, 255},
	{120, 230, 90, 255},
	{60, 220, 200, 255},
	{80, 170, 255, 255},
	{150, 120, 255, 255},
	{240, 110, 230, 255},
}

track_colour :: proc(note_index: int) -> rl.Color {
	return TRACK_COLOURS[note_index % len(TRACK_COLOURS)]
}

// ---------------------------------------------------------------------------
// The board, in millimetres
// ---------------------------------------------------------------------------

// Every place on any board: string s, semitone n is index s * FB_STRIDE + n.
FB_STRIDE :: music.BOARD_MAX_SEMIS + 1
FB_MAX_PLACES :: music.BOARD_MAX_STRINGS * FB_STRIDE

// Where a place is on board `b`: across it (mm from the middle) and down it
// (mm from the nut). From the instrument file's board_mm: the string length,
// and how far apart the outer strings are at the nut and at the bridge.
fb_place_mm :: proc(b: ^music.Board, s, semis: int) -> [2]f32 {
	down := b.length_mm * (1 - math.pow(2, -f32(semis) / 12))
	spread := b.nut_mm + (b.bridge_mm - b.nut_mm) * down / b.length_mm
	half := f32(max(int(b.n_strings) - 1, 1)) / 2
	return {(f32(s) - half) / (2 * half) * spread, down}
}

// The distances for the board they were worked out for (a cache: rebuilt
// when another instrument's board is asked about).
@(private = "file")
fb_dist_table: [FB_MAX_PLACES][FB_MAX_PLACES]f32
@(private = "file")
fb_dist_for: music.Board
@(private = "file")
fb_dist_ready: bool

// Millimetres between two places on the active layer's board.
fb_dist :: proc(a, b: Fb_Pos) -> f32 {
	bd := fb_board()
	if bd == nil do return 0
	same := fb_dist_ready && fb_dist_for.n_strings == bd.n_strings && fb_dist_for.strings == bd.strings && fb_dist_for.length_mm == bd.length_mm && fb_dist_for.nut_mm == bd.nut_mm && fb_dist_for.bridge_mm == bd.bridge_mm
	if !same {
		n := int(bd.n_strings)
		for i in 0 ..< n * FB_STRIDE {
			pi := fb_place_mm(bd, i / FB_STRIDE, i % FB_STRIDE)
			for j in 0 ..< n * FB_STRIDE {
				pj := fb_place_mm(bd, j / FB_STRIDE, j % FB_STRIDE)
				d := pi - pj
				fb_dist_table[i][j] = math.sqrt(d.x * d.x + d.y * d.y)
			}
		}
		fb_dist_for = bd^
		fb_dist_ready = true
	}
	return fb_dist_table[a.string * FB_STRIDE + a.semis][b.string * FB_STRIDE + b.semis]
}

// ---------------------------------------------------------------------------
// Choosing places
// ---------------------------------------------------------------------------

// How much a place costs, coming from the last step's places (`prev`, empty
// for the first note): lower is better.
@(private = "file")
place_cost :: proc(p: Fb_Pos, prev: []Fb_Pos, mode: Track_Mode) -> f32 {
	// Beyond the board's reach (a cello's thumb position) is beyond this
	// app: only if nothing else will do.
	cost: f32 = p.semis > fb_reach() ? 100000 : 0
	if len(prev) == 0 || mode == .Best {
		// As near the nut as it goes: the open string, or the lowest
		// position. (Best, always; the others, for the first note.) A hair
		// of distance breaks a tie.
		near := f32(1e9)
		for q in prev do near = min(near, fb_dist(q, p))
		return cost + f32(p.semis) * 1000 + (len(prev) > 0 ? near : 0)
	}
	best := f32(1e9)
	for q in prev {
		d := fb_dist(q, p)
		switch mode {
		case .Same_String:
			// Staying on a string beats any distance.
			if q.string != p.string do d += 10000
		case .Nearest:
			if q.string == p.string do d -= 0.01 // a tie keeps the string
		case .Best:
		}
		best = min(best, d)
	}
	return cost + best
}

// Places for the notes of one step (one note, or a chord: a double stop, a
// strum), each on its own string, at the least total cost. Notes that are not
// on the board get none (ok false). Searched depth first, giving up on any
// branch that already costs more than the best found.
fb_choose_step :: proc(midis: []int, prev: []Fb_Pos, mode: Track_Mode, out: []Fb_Pos) {
	Search :: struct {
		midis:      []int,
		prev:       []Fb_Pos,
		mode:       Track_Mode,
		n, strings: int,
		pick, best: [music.BOARD_MAX_STRINGS]int,
		best_cost:  f32,
		found:      bool,
	}
	walk :: proc(st: ^Search, k: int, used: u8, cost: f32) {
		if cost >= st.best_cost do return
		if k == st.n {
			st.best_cost = cost
			st.best = st.pick
			st.found = true
			return
		}
		for s in 0 ..< st.strings {
			if used & (1 << u8(s)) != 0 do continue
			semis := st.midis[k] - fb_open(s)
			if semis < 0 || semis > fb_semis() do continue
			st.pick[k] = s
			walk(st, k + 1, used | (1 << u8(s)), cost + place_cost({true, s, semis}, st.prev, st.mode))
		}
		// Leaving a note off costs more than any place, so it only happens
		// when there is no string for it.
		st.pick[k] = -1
		walk(st, k + 1, used, cost + 1e9)
	}
	for &o in out do o = {}
	st := Search{midis = midis, prev = prev, mode = mode, strings = fb_strings(), best_cost = 1e30}
	st.n = min(len(midis), st.strings, len(out))
	if st.n == 0 do return
	walk(&st, 0, 0, 0)
	if !st.found do return
	for k in 0 ..< st.n {
		if st.best[k] >= 0 do out[k] = {true, st.best[k], midis[k] - fb_open(st.best[k])}
	}
}

// Kept for single notes (and the tests): where one note goes after `prev`.
fb_choose :: proc(midi: int, prev: Fb_Pos, mode: Track_Mode) -> Fb_Pos {
	out: [1]Fb_Pos
	m := [1]int{midi}
	if prev.ok {
		pv := [1]Fb_Pos{prev}
		fb_choose_step(m[:], pv[:], mode, out[:])
	} else {
		fb_choose_step(m[:], nil, mode, out[:])
	}
	return out[0]
}

Tracked :: struct {
	pos:   Fb_Pos,
	midi:  int,
	index: int, // the note, in the layer
	step:  int, // which step (note or chord) of the layer: picks the colour
}

// Notes starting this close together, all while the first still sounds, are
// one step: played together, on different strings (a double stop, a chord,
// a strum - which in a song file is often a tick or two apart). 6 ticks is a
// quarter of a beat.
STRUM_TICKS :: 6

// The last `steps` steps of `t` up to the one starting at or before
// `upto_tick` - or, with `upto_note` >= 0, up to the step holding that note.
// Places are chosen from the start of the layer, so a note's place does not
// change as the window moves on. Fills `out` with their notes, oldest first;
// returns how many.
fb_track :: proc(t: ^music.Track, upto_tick: i32, upto_note: int, mode: Track_Mode, steps: int, out: []Tracked) -> int {
	if steps <= 0 || len(out) == 0 do return 0
	ring: [TRAIL_CAP]Tracked
	count := 0
	step := 0
	prev_buf: [music.BOARD_MAX_STRINGS]Fb_Pos
	prev := prev_buf[:0]
	first_note_of_window := 0 // ring index where the kept steps begin
	step_start: [TRACK_MAX + 1]int // ring positions of recent step starts
	i := 0
	for i < len(t.notes) {
		// Gather the step.
		first := t.notes[i]
		if upto_note < 0 && first.tick > upto_tick do break
		j := i + 1
		for j < len(t.notes) && j - i < fb_strings() {
			nj := t.notes[j]
			if nj.tick - first.tick > STRUM_TICKS || nj.tick >= first.tick + first.len do break
			j += 1
		}
		if upto_note >= 0 && i > upto_note do break
		midis: [music.BOARD_MAX_STRINGS]int
		for k in i ..< j do midis[k - i] = music.pitch_midi(t.notes[k].pitch)
		places: [music.BOARD_MAX_STRINGS]Fb_Pos
		fb_choose_step(midis[:j - i], prev, mode, places[:])
		n_placed := 0
		for k in 0 ..< j - i {
			if !places[k].ok do continue // not on the board: no place, no line
			if n_placed == 0 {
				step_start[step % (TRACK_MAX + 1)] = count
			}
			ring[count % len(ring)] = {places[k], midis[k], i + k, step}
			count += 1
			n_placed += 1
		}
		if n_placed > 0 {
			prev = prev_buf[:0]
			for k in 0 ..< j - i do if places[k].ok {prev_buf[len(prev)] = places[k]; prev = prev_buf[:len(prev) + 1]}
			step += 1
		}
		i = j
	}
	if step == 0 do return 0
	keep := min(steps, step, TRACK_MAX)
	first_note_of_window = step_start[(step - keep) % (TRACK_MAX + 1)]
	n := min(count - first_note_of_window, len(out))
	for k in 0 ..< n do out[k] = ring[(count - n + k) % len(ring)]
	return n
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

// From colour a (t = 0) to colour b (t = 1).
colour_mix :: proc(a, b: rl.Color, t: f32) -> rl.Color {
	l :: proc(x, y: u8, t: f32) -> u8 {return u8(f32(x) + (f32(y) - f32(x)) * clamp(t, 0, 1))}
	return {l(a.r, b.r, t), l(a.g, b.g, t), l(a.b, b.b, t), l(a.a, b.a, t)}
}

@(private = "file")
fb_point :: proc(p: Fb_Pos) -> rl.Vector2 {
	// Past the end of what the board shows: pinned to its end.
	y := fb_in_view(p.semis) ? fb_y(p.semis) : FB_END_Y + 4
	return {fb_x(p.string, y), y}
}

// A line that blends from one colour to the other, in pieces.
@(private = "file")
gradient_line :: proc(a, b: rl.Vector2, ca, cb: rl.Color, width: f32) {
	PIECES :: 16
	for k in 0 ..< PIECES {
		t0 := f32(k) / PIECES
		t1 := f32(k + 1) / PIECES
		rl.DrawLineEx(a + (b - a) * t0, a + (b - a) * t1, width, colour_mix(ca, cb, (t0 + t1) / 2))
	}
}

@(private = "file")
arrow_head :: proc(from, to: rl.Vector2, back: f32, c: rl.Color) {
	d := to - from
	l := math.sqrt(d.x * d.x + d.y * d.y)
	if l < 1 do return
	u := d / l
	tip := to - u * back
	side := rl.Vector2{-u.y, u.x}
	base := tip - u * 8
	rl.DrawTriangle(tip, base - side * 4.5, base + side * 4.5, c)
	rl.DrawTriangle(tip, base + side * 4.5, base - side * 4.5, c)
}

// Draw the trail: lines first, then the notes on top. Older steps fainter.
// Each note of a step gets one line in: from the note before; between chords
// of the same size, voice by voice; otherwise from the nearest note of the
// step before (a fan of lines into a chord, one line out of it).
fb_track_draw :: proc(list: []Tracked) {
	n := len(list)
	if n == 0 do return
	first, last := list[0].step, list[n - 1].step
	steps := last - first + 1
	fade :: proc(c: rl.Color, rank, steps: int) -> rl.Color {
		a := 0.35 + 0.65 * f32(rank + 1) / f32(steps)
		return {c.r, c.g, c.b, u8(f32(c.a) * a)}
	}
	for b in list {
		if b.step == first do continue
		// Where it came from. Between two chords of the same size, voice by
		// voice (lowest to lowest, and so on up); otherwise the nearest note
		// of the step before.
		size :: proc(list: []Tracked, step: int) -> int {
			c := 0
			for x in list do if x.step == step do c += 1
			return c
		}
		rank :: proc(list: []Tracked, it: Tracked) -> int {
			r := 0
			for x in list do if x.step == it.step && x.midi < it.midi do r += 1
			return r
		}
		from := -1
		if nb := size(list, b.step); nb > 1 && nb == size(list, b.step - 1) {
			rb := rank(list, b)
			for a, k in list do if a.step == b.step - 1 && rank(list, a) == rb do from = k
		} else {
			best := f32(1e9)
			for a, k in list {
				if a.step != b.step - 1 do continue
				d := fb_dist(a.pos, b.pos)
				if d < best {best = d; from = k}
			}
		}
		if from < 0 do continue
		a := list[from]
		if a.pos == b.pos do continue
		ca := fade(track_colour(a.step), a.step - first, steps)
		cb := fade(track_colour(b.step), b.step - first, steps)
		pa, pb := fb_point(a.pos), fb_point(b.pos)
		if a.pos.string == b.pos.string {
			// Along the string: a line down the string itself, straight
			// through the places on the way.
			s := a.pos.string
			PIECES :: 24
			for q in 0 ..< PIECES {
				t0 := f32(q) / PIECES
				t1 := f32(q + 1) / PIECES
				y0 := pa.y + (pb.y - pa.y) * t0
				y1 := pa.y + (pb.y - pa.y) * t1
				rl.DrawLineEx({fb_x(s, y0), y0}, {fb_x(s, y1), y1}, 3, colour_mix(ca, cb, (t0 + t1) / 2))
			}
			arrow_head(pa, pb, 7, cb)
		} else {
			// Across the strings: straight from one to the other.
			gradient_line(pa, pb, ca, cb, 3)
			arrow_head(pa, pb, 7, cb)
		}
	}
	for it in list {
		p := fb_point(it.pos)
		c := fade(track_colour(it.step), it.step - first, steps)
		rl.DrawCircleV(p, 6.5, c)
		if it.step == last do rl.DrawCircleLines(i32(p.x), i32(p.y), 8.5, rl.WHITE)
		if !fb_in_view(it.pos.semis) {
			// Further down than the board shows: pinned to its end, named.
			text(fmt.tprintf("%s v", fb_name(it.midi)), p.x + 9, p.y - 5, COL_TEXT)
		}
	}
}

// The trail as the fingerboard shows it now: the last N steps of the active
// layer up to the playhead, or up to the selected note when stopped. Empty
// when tracking is off. Oldest first.
fb_current_trail :: proc(out: []Tracked) -> int {
	t := active_track()
	if t == nil || !g.fb_track || fb_board() == nil do return 0
	if g.player.playing do return fb_track(t, player_tick(&g.player, &g.song), -1, g.fb_track_mode, g.fb_track_n, out)
	if g.selected >= 0 && g.selected < len(t.notes) do return fb_track(t, 0, g.selected, g.fb_track_mode, g.fb_track_n, out)
	return 0
}

// How strongly a trail note shows its tracking colour (its step's rank among
// the trail's, oldest 0): the newest fully, each older step a step less, as
// on the board.
trail_weight :: proc(rank, steps: int) -> f32 {
	return f32(rank + 1) / f32(max(steps, 1))
}
