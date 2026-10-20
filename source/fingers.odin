package app

/*
    The Fingers view: the Score view for a bowed string instrument (violin,
    viola, cello, contrabass), with the fingering shown as it is played.

    The Score button (and V) go round Grid -> Score -> Fingers -> Grid; Fingers
    is skipped when the active layer is not a bowed string instrument.

        +-------------+---------------------------------------------+
        |  |  |##|  | |      0  3      0  3 4 4  3 1      <- finger |
        |  |  |##|  | |  ===|==o==o====|==o=o=o==o=o=====  (string's |
        |  |  |##|  | |      G  B      G  B C C  B A        colour) |
        |  |  |##|  | |                               <- letter    |
        |  O  (3) O  O|                                             |
        +-------------+---------------------------------------------+
         C  G  D  A      the page: the Score view's, unchanged

    THE LANES (left): one per string, lowest on the left, each in its own
    colour. The notes come down them toward a ring at the bottom - a block
    as long as the note, the finger on it - and the ring lights up with the
    finger while the note sounds: Play, and the hand's next moves are in
    sight a bar ahead. Stopped, it shows the selected note (or the cursor).

    THE PAGE (right): the Score view, with each note's finger above the staff
    in its string's colour, and its letter below.

    THE FINGERING (finger_plan): every note of the layer gets a string and a
    finger - 0 an open string, 1-4, T the thumb - from the hand positions in
    the instrument's file (the same ones the Helper draws: a cello's 1st
    position puts fingers 1-4 a semitone apart from a tone up, a violin's
    tone, tone, semitone; the contrabass plays 1, 2 and 4). Chosen for the
    whole layer at once, as a player marks a part up (a shortest path over
    the notes, the hand position the state):

      * a note on its position's finger costs nothing; an open string costs
        nothing in any position (and is where a shift is hidden); a finger
        a semitone off its place inside the hand (a violinist's low 2 or
        high 3) costs a little, a stretch beyond the hand more;
      * changing position costs more the further the hand goes - less across
        an open string or a rest;
      * the further from the instrument's home position (its board_default,
        1st position), the more it costs: 1st position when it will do;
      * a chord (a double stop) is one step: its notes on different strings,
        in one position.

    Worked out again only when the notes (or the instrument) change.
*/

import "core:fmt"
import "music"
import rl "vendor:raylib"

FINGER_THUMB :: 5

Finger_Note :: struct {
	ok:     bool, // false: no place for it in any position
	string: i8,
	finger: i8, // 0 open, 1-4, FINGER_THUMB
	pos:    i8, // the hand position (the board's list)
	step:   i32, // notes with the same step are a chord
}

// The plan for one layer, kept until its notes change (App.fingers).
Finger_Plan :: struct {
	notes: [dynamic]Finger_Note,
	key:   u64,
}

// The strings' colours, lowest first: a cello's C orange, G green, D blue,
// A red; a violin's G, D, A, E the same way round.
STRING_COLOURS := [?]rl.Color {
	{247, 152, 36, 255},
	{78, 186, 92, 255},
	{52, 140, 238, 255},
	{238, 72, 64, 255},
	{186, 120, 240, 255},
	{240, 220, 80, 255},
}

string_colour :: proc(s: int) -> rl.Color {return STRING_COLOURS[clamp(s, 0, len(STRING_COLOURS) - 1)]}

finger_label :: proc(f: i8) -> string {
	return f == FINGER_THUMB ? "T" : fmt.tprint(f)
}

// A bowed string instrument: a fingerboard, unfretted, with hand positions.
fingers_board :: proc() -> ^music.Board {
	b := fb_board()
	if b == nil || b.frets || b.n_positions == 0 do return nil
	return b
}

fingers_on :: proc() -> bool {return g.view == .Fingers && fingers_board() != nil}

// ---------------------------------------------------------------------------
// The fingering
// ---------------------------------------------------------------------------

// The fingering of the active layer, one per note (index as in t.notes).
finger_plan :: proc() -> []Finger_Note {
	t := active_track()
	b := fingers_board()
	if t == nil || b == nil do return nil
	// What the plan depends on: the notes and the board.
	h := u64(14695981039346656037)
	mix :: proc(h: ^u64, v: u64) {h^ = (h^ ~ v) * 1099511628211}
	for n in t.notes do mix(&h, u64(u32(n.tick)) | u64(u32(n.len)) << 32 ~ u64(music.pitch_midi(n.pitch)) << 52)
	mix(&h, u64(len(t.notes)))
	bytes := transmute([size_of(music.Board)]u8)b^
	for x in bytes do mix(&h, u64(x))
	p := &g.fingers
	if p.key == h && len(p.notes) == len(t.notes) do return p.notes[:]
	resize(&p.notes, len(t.notes))
	finger_plan_make(t, b, p.notes[:])
	p.key = h
	return p.notes[:]
}

// One way to play a note in a position.
@(private = "file")
Option :: struct {
	string: i8,
	finger: i8,
	cost:   f32,
}

// The ways to play `midi` in position `p`: on each string, open, or on the
// finger that stops it (or one a semitone off it).
@(private = "file")
options_in :: proc(b: ^music.Board, p: ^music.Board_Position, midi: int, out: []Option) -> int {
	n := 0
	for s in 0 ..< int(b.n_strings) {
		semis := midi - int(b.strings[s])
		if semis < 0 || semis > int(b.semis) do continue
		if semis == 0 {
			out[n] = {i8(s), 0, 0}
			n += 1
			continue
		}
		// The hand's frame: its lowest and highest finger.
		lo, hi := 99, 0
		for f in p.fingers do if f > 0 {lo = min(lo, int(f)); hi = max(hi, int(f))}
		best, best_cost := i8(-1), f32(1e9)
		for k in 0 ..< 5 {
			f := k < 4 ? int(p.fingers[k]) : int(p.thumb)
			if f <= 0 do continue
			d := abs(semis - f)
			if d > 1 do continue
			// A semitone off a finger: inside the frame, a low 2 or a high 3
			// (a violinist's every key); outside it, a stretch.
			cost := f32(0.1)
			if d == 1 do cost = semis > lo && semis < hi ? 0.3 : 1.5
			// Between two fingers, the middle ones move: a low 2, a high 3.
			if k == 0 || k == 3 do cost += 0.01
			if cost < best_cost {best, best_cost = i8(k < 4 ? k + 1 : FINGER_THUMB), cost}
		}
		if best >= 0 {
			out[n] = {i8(s), best, best_cost}
			n += 1
		}
	}
	return n
}

// Where the hand is in a position: its lowest finger's place.
@(private = "file")
pos_base :: proc(p: ^music.Board_Position) -> f32 {
	lo := 99
	for f in p.fingers do if f > 0 do lo = min(lo, int(f))
	if p.thumb > 0 do lo = min(lo, int(p.thumb))
	return f32(lo == 99 ? 0 : lo)
}

finger_plan_make :: proc(t: ^music.Track, b: ^music.Board, out: []Finger_Note) {
	for &o in out do o = {}
	np := int(b.n_positions)
	if np == 0 || len(t.notes) == 0 do return
	INF :: f32(1e18)
	MISS :: f32(40) // a note no position plays

	// The steps: a note, or the notes of a chord.
	Step :: struct {
		first, n:   int,
		tick, end:  i32,
	}
	steps := make([dynamic]Step, context.temp_allocator)
	for i := 0; i < len(t.notes); {
		f := t.notes[i]
		j := i + 1
		for j < len(t.notes) && j - i < int(b.n_strings) {
			nj := t.notes[j]
			if nj.tick - f.tick > STRUM_TICKS || nj.tick >= f.tick + f.len do break
			j += 1
		}
		end: i32
		for k in i ..< j do end = max(end, t.notes[k].tick + t.notes[k].len)
		append(&steps, Step{i, j - i, f.tick, end})
		i = j
	}
	ns := len(steps)
	// For each step and position: the best way to play it there.
	Choice :: struct {
		cost:     f32,
		all_open: bool,
		picks:    [music.BOARD_MAX_STRINGS]Option,
		played:   [music.BOARD_MAX_STRINGS]bool,
	}
	choice := make([]Choice, ns * np, context.temp_allocator)
	for st, si in steps {
		for p in 0 ..< np {
			pos := &b.positions[p]
			opts: [music.BOARD_MAX_STRINGS][music.BOARD_MAX_STRINGS]Option
			nopt: [music.BOARD_MAX_STRINGS]int
			for k in 0 ..< st.n {
				nopt[k] = options_in(b, pos, music.pitch_midi(t.notes[st.first + k].pitch), opts[k][:])
			}
			// Each note on its own string, at the least cost (a few notes,
			// a few strings: try them all).
			Search :: struct {
				opts:   ^[music.BOARD_MAX_STRINGS][music.BOARD_MAX_STRINGS]Option,
				nopt:   ^[music.BOARD_MAX_STRINGS]int,
				n:      int,
				pick:   [music.BOARD_MAX_STRINGS]int,
				best:   [music.BOARD_MAX_STRINGS]int,
				cost:   f32,
			}
			walk :: proc(s: ^Search, k: int, used: u8, cost: f32) {
				if cost >= s.cost do return
				if k == s.n {s.cost = cost; s.best = s.pick; return}
				for o in 0 ..< s.nopt[k] {
					str := s.opts[k][o].string
					if used & (1 << u8(str)) != 0 do continue
					s.pick[k] = o
					walk(s, k + 1, used | (1 << u8(str)), cost + s.opts[k][o].cost)
				}
				s.pick[k] = -1
				walk(s, k + 1, used, cost + MISS)
			}
			s := Search{opts = &opts, nopt = &nopt, n = st.n, cost = INF}
			walk(&s, 0, 0, 0)
			c := &choice[si * np + p]
			// The instrument's home position (1st) first, then the nearer.
			home := pos_base(&b.positions[b.default_pos])
			c.cost = s.cost + (0.04 * abs(pos_base(pos) - home) + 0.002 * f32(abs(p - int(b.default_pos)))) * f32(st.n)
			c.all_open = true
			for k in 0 ..< st.n {
				if s.best[k] >= 0 {
					c.picks[k] = opts[k][s.best[k]]
					c.played[k] = true
					if c.picks[k].finger != 0 do c.all_open = false
				} else {
					c.all_open = false
				}
			}
		}
	}
	// The shortest path through the positions.
	total := make([]f32, ns * np, context.temp_allocator)
	from := make([]i32, ns * np, context.temp_allocator)
	for p in 0 ..< np {
		total[p] = choice[p].cost + 0.001 * f32(abs(p - int(b.default_pos)))
		from[p] = -1
	}
	beat := music.beat_ticks(&g.song)
	for si in 1 ..< ns {
		rest := steps[si].tick - steps[si - 1].end >= beat
		for q in 0 ..< np {
			cq := &choice[si * np + q]
			best, bp := INF, -1
			for p in 0 ..< np {
				move: f32
				if p != q {
					move = 2 + 0.25 * abs(pos_base(&b.positions[p]) - pos_base(&b.positions[q]))
					// A shift hides behind an open string or a rest.
					if rest || cq.all_open || choice[(si - 1) * np + p].all_open do move *= 0.3
				}
				if c := total[(si - 1) * np + p] + move; c < best {best, bp = c, p}
			}
			total[si * np + q] = best + cq.cost
			from[si * np + q] = i32(bp)
		}
	}
	// Back along it.
	q := 0
	for p in 1 ..< np do if total[(ns - 1) * np + p] < total[(ns - 1) * np + q] do q = p
	for si := ns - 1; si >= 0; si -= 1 {
		c := &choice[si * np + q]
		st := steps[si]
		for k in 0 ..< st.n {
			if !c.played[k] do continue
			out[st.first + k] = {true, c.picks[k].string, c.picks[k].finger, i8(q), i32(si)}
		}
		if si > 0 do q = int(from[si * np + q])
	}
}

// ---------------------------------------------------------------------------
// The lanes
// ---------------------------------------------------------------------------

LANES_W :: f32(272)

// The panel the lanes are in: left of the page, as tall as it.
lanes_area :: proc() -> rl.Rectangle {
	a := score_area()
	return {a.x - LANES_W, a.y, LANES_W, a.height}
}

// The tick the lanes show at their rings: the playhead while playing; else
// the selected note, or the cursor.
lanes_now :: proc() -> f32 {
	if g.player.playing do return player_tick_at(&g.player, &g.song, rl.GetTime())
	if t := active_track(); t != nil && g.selected >= 0 && g.selected < len(t.notes) do return f32(t.notes[g.selected].tick)
	return f32(g.cursor_tick)
}

lanes_draw :: proc() {
	b := fingers_board()
	t := active_track()
	if b == nil || t == nil do return
	plan := finger_plan()
	r := lanes_area()
	ink := score_ink()
	rl.DrawRectangleRec(r, ink.paper)
	rl.DrawLineEx({r.x + r.width - 1, r.y}, {r.x + r.width - 1, r.y + r.height}, 1, COL_RULE)
	n := int(b.n_strings)
	lane_w := (r.width - 16) / f32(n)
	rad := min(lane_w * 0.38, 25)
	ring_y := r.y + r.height - rad - 26 // the rings' middle
	top := r.y + 24 // under the hand position's name
	now := lanes_now()
	// A bar (at least two beats) from the top of the lanes to the rings.
	look := f32(max(music.bar_ticks(&g.song), 2 * music.beat_ticks(&g.song)))
	per_tick := (ring_y - top) / look
	lane_x :: proc(r: rl.Rectangle, lane_w: f32, s: int) -> f32 {return r.x + 8 + (f32(s) + 0.5) * lane_w}

	for s in 0 ..< n {
		x := lane_x(r, lane_w, s)
		rl.DrawLineEx({x, top}, {x, ring_y - rad}, 1.5, with_alpha(string_colour(s), 110))
	}

	// The blocks: every note from now to a bar ahead, down its string's lane,
	// cut off at the ring (and at the top).
	sounding: [music.BOARD_MAX_STRINGS]i8
	for &f in sounding do f = -1
	for note, i in t.notes {
		if i >= len(plan) || !plan[i].ok do continue
		t0, t1 := f32(note.tick), f32(note.tick + note.len)
		if t1 <= now || t0 > now + look do continue
		fn := plan[i]
		if t0 <= now do sounding[fn.string] = fn.finger
		col := string_colour(int(fn.string))
		x := lane_x(r, lane_w, int(fn.string))
		w := lane_w * 0.72
		y_bot := min(ring_y - (t0 - now) * per_tick, ring_y)
		y_top := max(ring_y - (t1 - now) * per_tick + 2, top) // a gap between notes
		if y_bot - y_top < 1 do continue
		br := rl.Rectangle{x - w / 2, y_top, w, y_bot - y_top}
		dark := colour_mix(col, {0, 0, 0, 255}, 0.45)
		rl.DrawRectangleGradientH(i32(br.x), i32(br.y), i32(br.width), i32(br.height), col, dark)
		rl.DrawRectangleRoundedLinesEx(br, 0.12, 4, 1, colour_mix(col, {255, 255, 255, 255}, 0.3))
		// The finger, near the block's bottom edge (where it is played).
		lbl := finger_label(fn.finger)
		lh := f32(FONT_BIG)
		ly := max(y_bot - lh - 6, br.y + 2)
		if br.height >= lh * 0.8 {
			text(lbl, x - text_width(lbl, FONT_BIG) / 2 + 1, ly + 1, {0, 0, 0, 140}, FONT_BIG)
			text(lbl, x - text_width(lbl, FONT_BIG) / 2, ly, rl.WHITE, FONT_BIG)
		}
	}

	// The rings: lit, with the finger, while their string sounds.
	for s in 0 ..< n {
		x := lane_x(r, lane_w, s)
		col := string_colour(s)
		if f := sounding[s]; f >= 0 {
			rl.DrawCircleV({x, ring_y}, rad + 7, with_alpha(col, 60))
			rl.DrawCircleV({x, ring_y}, rad + 2, {0, 0, 0, 255})
			rl.DrawCircleV({x, ring_y}, rad - 2, col)
			lbl := finger_label(f)
			text(lbl, x - text_width(lbl, FONT_BIG) / 2, ring_y - f32(FONT_BIG) / 2 - 1, rl.WHITE, FONT_BIG)
		} else {
			rl.DrawRing({x, ring_y}, rad - 3, rad, 0, 360, 48, col)
		}
		// The string's name.
		name := fb_string_name(s)
		text(name, x - text_width(name) / 2, ring_y + rad + 6, ink.faint)
	}
	// Which hand position the sounding (or next) note is in.
	pos := -1
	for note, i in t.notes {
		if i >= len(plan) || !plan[i].ok || f32(note.tick + note.len) <= now do continue
		pos = int(plan[i].pos)
		break
	}
	if pos >= 0 && pos < int(b.n_positions) {
		text(board_pos_name(b, pos), r.x + 8, r.y + 6, ink.faint)
	}
}

@(private = "file")
board_pos_name :: proc(b: ^music.Board, i: int) -> string {
	return music.board_position_name(&b.positions[i])
}

// ---------------------------------------------------------------------------
// The page: fingers above, letters below
// ---------------------------------------------------------------------------

// A note head on a line, for the marks.
Finger_Mark :: struct {
	x, y:      f32,
	stem_end:  f32,
	up:        bool,
	note:      int,
}

// Collect the heads of one bar's chords and rests (after bar_draw has placed
// them) into `marks`.
fingers_collect :: proc(evs: []Ev, marks: ^[dynamic]Finger_Mark) {
	for &e in evs {
		if e.rest do continue
		for h in e.heads[:e.n] {
			if h.tie_in do continue // held on: fingered already
			append(marks, Finger_Mark{h.x, h.y, e.stem_end, e.up, h.note})
		}
	}
}

// One line's marks: the finger over the staff in its string's colour (a
// chord's stacked, the highest note on top), the letter under it. Each row
// clears the line's heads and stems.
fingers_marks_draw :: proc(s: ^Sys, marks: []Finger_Mark, ink: Score_Ink) {
	t := active_track()
	plan := finger_plan()
	if t == nil || len(marks) == 0 do return
	above := score_staff_top(s) - 1.8 * SP
	below := score_staff_bottom(s) + 2.2 * SP
	for m in marks {
		above = min(above, m.y - 1.6 * SP)
		below = max(below, m.y + 1.6 * SP)
		if m.up do above = min(above, m.stem_end - 0.6 * SP)
		else do below = max(below, m.stem_end + 0.9 * SP)
	}
	key := int(g.song.key)
	// A chord (or a rolled one, its notes a tick or two apart): one column,
	// at its first note, stacked by pitch.
	same :: proc(plan: []Finger_Note, a, b: int) -> bool {
		if a == b do return true
		if a >= len(plan) || b >= len(plan) || !plan[a].ok || !plan[b].ok do return false
		return plan[a].step == plan[b].step
	}
	// The stacks stay inside the line's band, over a stem if they must.
	ROW :: f32(11)
	tallest := 1
	for m in marks {
		k := 0
		for o in marks do if same(plan, o.note, m.note) do k += 1
		tallest = max(tallest, k)
	}
	above = max(above, s.y0 + 2 + f32(tallest) * ROW)
	below = min(below, s.y0 + sys_h() - f32(tallest) * ROW - 2)
	for m, i in marks {
		if m.note >= len(t.notes) do continue
		midi := music.pitch_midi(t.notes[m.note].pitch)
		rank, letters := 0, 0
		x := m.x
		for o, k in marks {
			if k == i || !same(plan, o.note, m.note) do continue
			x = min(x, o.x)
			if o.y > m.y do rank += 1 // the fingers: the highest note's on top
			if o.y < m.y do letters += 1 // the letters: the highest note's first
		}
		if m.note < len(plan) && plan[m.note].ok {
			fn := plan[m.note]
			lbl := finger_label(fn.finger)
			y := above - f32(rank) * ROW - 10
			text(lbl, x - text_width(lbl) / 2, y, colour_mix(string_colour(int(fn.string)), ink.paper, g.score_paper ? 0.1 : 0))
		}
		lt := note_letter(midi, key)
		text(lt, x - text_width(lt) / 2, below + f32(letters) * ROW, ink.ink)
	}
}
