package app

/*
    Tracking (Cello Helper): where on the fingerboard each note of the layer is
    played, and the path the hand takes from one to the next.

    Every note of the active layer is given a place on the board - a string,
    and how far up it - one after another from the start of the layer, each
    chosen from where the previous one was:

      Same string   stay on the string you are on if it can play the note;
                    only when it cannot, go to the nearest place that can.
      Nearest       whichever place for the note is physically closest to the
                    last one, whatever string it is on.

    The first note goes wherever it sits lowest on the neck.

    "Physically closest" is measured on a real cello, not on the drawing: a
    full-size cello's strings are 695 mm long, nut to bridge; they are 23 mm
    apart outer to outer at the nut and 47 mm at the bridge (from a luthier's
    measurement chart), and semitone n is stopped 695 * (1 - 2^(-n/12)) mm
    from the nut. From that, the distance between every pair of places on the
    board is worked out once (fb_dist, a 120 x 120 table).

    The fingerboard then draws the last N notes up to the playhead (or up to
    the selected note, when stopped): each note filled with its own colour -
    the colours cycle, note by note - and the way from one to the next along
    the string (the string and the circles on the way coloured, blending from
    one note's colour into the next's), or, from string to string, an arrow
    straight across the board.
*/

import "core:math"
import "music"
import rl "vendor:raylib"

Track_Mode :: enum u8 {
	Same_String,
	Nearest,
}

TRACK_MODE_NAME := [Track_Mode]string {
	.Same_String = "Same string",
	.Nearest     = "Nearest",
}

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

CELLO_STRING_MM :: f32(695)
CELLO_NUT_SPREAD_MM :: f32(23) // C string to A string, at the nut
CELLO_BRIDGE_SPREAD_MM :: f32(47) // ...and at the bridge

FB_PLACES :: 4 * (FB_SEMIS + 1)

// Where a place is: across the board (mm from the middle) and down it (mm
// from the nut).
fb_place_mm :: proc(s, semis: int) -> [2]f32 {
	down := CELLO_STRING_MM * (1 - math.pow(2, -f32(semis) / 12))
	spread := CELLO_NUT_SPREAD_MM + (CELLO_BRIDGE_SPREAD_MM - CELLO_NUT_SPREAD_MM) * down / CELLO_STRING_MM
	return {(f32(s) - 1.5) / 3 * spread, down}
}

@(private = "file")
fb_dist_table: [FB_PLACES][FB_PLACES]f32
@(private = "file")
fb_dist_ready: bool

// Millimetres between two places on the board.
fb_dist :: proc(a, b: Fb_Pos) -> f32 {
	if !fb_dist_ready {
		for i in 0 ..< FB_PLACES {
			pi := fb_place_mm(i / (FB_SEMIS + 1), i % (FB_SEMIS + 1))
			for j in 0 ..< FB_PLACES {
				pj := fb_place_mm(j / (FB_SEMIS + 1), j % (FB_SEMIS + 1))
				d := pi - pj
				fb_dist_table[i][j] = math.sqrt(d.x * d.x + d.y * d.y)
			}
		}
		fb_dist_ready = true
	}
	return fb_dist_table[a.string * (FB_SEMIS + 1) + a.semis][b.string * (FB_SEMIS + 1) + b.semis]
}

// ---------------------------------------------------------------------------
// Choosing places
// ---------------------------------------------------------------------------

// Where a note would go, given where the last one was (`prev.ok` false for
// the first note). Not ok if the note is not on the board at all.
fb_choose :: proc(midi: int, prev: Fb_Pos, mode: Track_Mode) -> Fb_Pos {
	best: Fb_Pos
	if !prev.ok {
		// The first: as low on the neck as it goes.
		for s := 3; s >= 0; s -= 1 {
			n := midi - FB_OPEN[s]
			if n < 0 || n > FB_SEMIS do continue
			if !best.ok || n < best.semis do best = {true, s, n}
		}
		return best
	}
	if mode == .Same_String {
		n := midi - FB_OPEN[prev.string]
		if n >= 0 && n <= FB_SEMIS do return {true, prev.string, n}
	}
	best_d := f32(1e9)
	for s in 0 ..< 4 {
		n := midi - FB_OPEN[s]
		if n < 0 || n > FB_SEMIS do continue
		p := Fb_Pos{true, s, n}
		d := fb_dist(prev, p)
		// A tie keeps the string.
		if s == prev.string do d -= 0.01
		if d < best_d {best = p; best_d = d}
	}
	return best
}

Tracked :: struct {
	pos:   Fb_Pos,
	midi:  int,
	index: int, // in the layer: picks the colour
}

// The last `n` notes of `t` up to (and including) the one starting at or
// before `upto_tick` - or, with `upto_note` >= 0, up to that note. Places are
// chosen from the start of the layer, so a note's place does not change as the
// window moves on. Returns how many were filled in (oldest first).
fb_track :: proc(t: ^music.Track, upto_tick: i32, upto_note: int, mode: Track_Mode, out: []Tracked) -> int {
	if len(out) == 0 do return 0
	ring: [TRACK_MAX]Tracked
	count := 0
	prev: Fb_Pos
	for note, i in t.notes {
		if upto_note >= 0 {
			if i > upto_note do break
		} else if note.tick > upto_tick {
			break
		}
		m := music.pitch_midi(note.pitch)
		p := fb_choose(m, prev, mode)
		if !p.ok do continue // off the board: no place, no line through it
		prev = p
		ring[count % TRACK_MAX] = {p, m, i}
		count += 1
	}
	n := min(count, len(out), TRACK_MAX)
	for k in 0 ..< n do out[k] = ring[(count - n + k) % TRACK_MAX]
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
	y := fb_y(p.semis)
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

// The trail as the fingerboard shows it now: the last N notes of the active
// layer up to the playhead, or up to the selected note when stopped. Empty
// when tracking is off. Oldest first.
fb_current_trail :: proc(out: []Tracked) -> int {
	t := active_track()
	if t == nil || !g.fb_track do return 0
	n := min(g.fb_track_n, len(out))
	if g.player.playing do return fb_track(t, player_tick(&g.player, &g.song), -1, g.fb_track_mode, out[:n])
	if g.selected >= 0 && g.selected < len(t.notes) do return fb_track(t, 0, g.selected, g.fb_track_mode, out[:n])
	return 0
}

// How strongly the k-th of n trail notes (oldest first) shows its tracking
// colour: the newest fully, each older one a step less, as on the board.
trail_weight :: proc(k, n: int) -> f32 {
	return f32(k + 1) / f32(max(n, 1))
}

// Draw the trail: lines first, then the notes on top. Older notes fainter.
fb_track_draw :: proc(list: []Tracked) {
	n := len(list)
	if n == 0 do return
	fade :: proc(c: rl.Color, k, n: int) -> rl.Color {
		a := 0.35 + 0.65 * f32(k + 1) / f32(n)
		return {c.r, c.g, c.b, u8(f32(c.a) * a)}
	}
	for k in 1 ..< n {
		a, b := list[k - 1], list[k]
		if a.pos == b.pos do continue
		ca := fade(track_colour(a.index), k - 1, n)
		cb := fade(track_colour(b.index), k, n)
		pa, pb := fb_point(a.pos), fb_point(b.pos)
		if a.pos.string == b.pos.string {
			// Along the string: the string itself, and every circle on the
			// way, coloured in.
			s := a.pos.string
			lo, hi := min(a.pos.semis, b.pos.semis), max(a.pos.semis, b.pos.semis)
			PIECES :: 24
			for q in 0 ..< PIECES {
				t0 := f32(q) / PIECES
				t1 := f32(q + 1) / PIECES
				y0 := pa.y + (pb.y - pa.y) * t0
				y1 := pa.y + (pb.y - pa.y) * t1
				rl.DrawLineEx({fb_x(s, y0), y0}, {fb_x(s, y1), y1}, 3, colour_mix(ca, cb, (t0 + t1) / 2))
			}
			for semis in lo + 1 ..< hi {
				t := f32(semis - a.pos.semis) / f32(b.pos.semis - a.pos.semis)
				p := fb_point({true, s, semis})
				rl.DrawCircleLines(i32(p.x), i32(p.y), 4.5, colour_mix(ca, cb, t))
				rl.DrawCircleLines(i32(p.x), i32(p.y), 5.5, colour_mix(ca, cb, t))
			}
			arrow_head(pa, pb, 7, cb)
		} else {
			// Across the strings: straight from one to the other.
			gradient_line(pa, pb, ca, cb, 3)
			arrow_head(pa, pb, 7, cb)
		}
	}
	for k in 0 ..< n {
		it := list[k]
		p := fb_point(it.pos)
		c := fade(track_colour(it.index), k, n)
		rl.DrawCircleV(p, 6.5, c)
		if k == n - 1 do rl.DrawCircleLines(i32(p.x), i32(p.y), 8.5, rl.WHITE)
	}
}
