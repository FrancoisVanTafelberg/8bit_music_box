package app

/*
    The Score view: the sheet as sheet music.

    The Grid view (sheet.odin) is one tall staff of every step, four bars
    across, notes as bars of colour. The Score view shows the same song the
    way it would be printed: a page of up to four lines (systems), up to four
    bars each, on the staff the active layer's instrument is written on
    (clef.odin) - clef, key signature and time signature at the start,
    notes with their heads, stems, flags and beams, dots, ties across bar
    lines, rests in the gaps, accidentals where the key and the bar need
    them, ledger lines. Only the active layer is drawn: it is that part's
    sheet. The V key (or the Score button under the sheet) switches views.

    Everything else works as on the grid, through the same code: a click
    places a note of the current length where it lands (the staff position
    is the pitch, in the key), drag moves one, right-click deletes, the
    wheel nudges; playing, tracking, suggesting, the microphone's take and
    the check marks all show on the notes. A page is the lines on screen, so
    Page play (and the page boxes, and page turning while following) goes a
    page of four lines at a time. Scroll play moves the page UP instead of
    sideways: the line being played is the top line until it has been played
    through; then the page glides up a line and the next one takes its place.

    Black paper and white ink by default; right-click the Score button (or
    Shift+V) for white paper and black ink.

    Drawn straight to the window at its full resolution, like everything
    else (window.odin): staff lines, note heads and clefs are sharp at any
    window size.

    Layout: bars are all the same width and time runs evenly across each
    (proportional spacing, as the grid), so the playhead moves steadily and
    a click lands where the time is. How it is written - which note values,
    what is tied, where the rests go - is worked out afresh every frame from
    the notes (score_bar), so nothing about it is saved: the song stays notes.
*/

import "core:fmt"
import "core:math"
import "music"
import rl "vendor:raylib"

Sheet_View :: enum u8 {
	Grid,
	Score,
}

SP :: f32(9) // a staff space, in canvas pixels
SCORE_SYSTEMS :: 4 // lines of music on a page
SCORE_MIN_BAR :: f32(150) // a line holds fewer bars before a bar gets narrower than this
SCORE_ML :: f32(14)
SCORE_MR :: f32(12)
GRAND_GAP :: 4 * SP // the treble staff's bottom line to the bass staff's top line
BAR_PAD_L :: 1.9 * SP // room at the start of a bar for an accidental
BAR_PAD_R :: 1.0 * SP
HEAD_RX :: 0.64 * SP
HEAD_RY :: 0.47 * SP
HEAD_ANGLE :: f32(-20)
STEM_LEN :: 3.5 * SP
BEAM_TH :: 0.5 * SP
BEAM_GAP :: 0.75 * SP // from one beam to the next
MIDDLE_C :: 28 // the step (C4) a grand staff splits at: here and up, the treble staff
MAX_HEADS :: 12

score_on :: proc() -> bool {return g.view == .Score}

// ---------------------------------------------------------------------------
// Colours: black paper by default, white on request
// ---------------------------------------------------------------------------

Score_Ink :: struct {
	paper, ink, line, faint, accent, bad: rl.Color,
}

score_ink :: proc() -> Score_Ink {
	if g.score_paper {
		return {paper = {248, 246, 238, 255}, ink = {18, 18, 24, 255}, line = {40, 40, 48, 255}, faint = {150, 150, 160, 255}, accent = {214, 120, 0, 255}, bad = {210, 40, 40, 255}}
	}
	return {paper = {0, 0, 0, 255}, ink = {236, 236, 242, 255}, line = {205, 205, 215, 255}, faint = {90, 90, 104, 255}, accent = COL_ACCENT, bad = COL_BAD}
}

view_toggle :: proc() {
	// Keep the same music in front of you: the page that holds the first
	// bar of the page being shown.
	first_bar := g.page * page_bars()
	g.view = g.view == .Grid ? .Score : .Grid
	g.page = clamp(first_bar / page_bars(), 0, page_count() - 1)
	if score_on() {
		set_status("Score view: the active layer as sheet music, %d lines of %d bars a page (V: back to the grid; Shift+V: paper)", SCORE_SYSTEMS, score_bars_per_system())
	} else {
		set_status("Grid view (V: the Score view)")
	}
}

paper_toggle :: proc() {
	g.score_paper = !g.score_paper
	set_status(g.score_paper ? "Score: black ink on white paper" : "Score: white ink on black")
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

score_area :: proc() -> rl.Rectangle {
	return {panel_w(), TOP_H, sheet_r() - panel_w(), f32(strip_y()) - 4 - TOP_H}
}

sys_h :: proc() -> f32 {return score_area().height / SCORE_SYSTEMS}

// How wide the start of a line is: clef, key signature, and (the first line
// only) the time signature.
score_header_w :: proc(first: bool) -> f32 {
	w := KEY_X + f32(abs(int(g.song.key))) * KEY_STEP + 0.6 * SP
	if first do w += TIME_W
	return w
}

KEY_X :: 4.0 * SP // the key signature's start, from the line's start
KEY_STEP :: 1.05 * SP // one accidental of it to the next
TIME_W :: 2.6 * SP

// Up to four bars a line; fewer when the sheet is narrow (the Helper on).
score_bars_per_system :: proc() -> i32 {
	a := score_area()
	usable := a.width - SCORE_ML - SCORE_MR - score_header_w(true)
	return clamp(i32(usable / SCORE_MIN_BAR), 1, 4)
}

system_ticks :: proc() -> i32 {return music.bar_ticks(&g.song) * score_bars_per_system()}

score_systems :: proc() -> int {
	bps := score_bars_per_system()
	return max(int((g.song.bars + bps - 1) / bps), 1)
}

// The line at the top of the sheet. Scroll play: the line being played is
// the top line, whole, until it has been played to its end; only when the
// playhead has moved on to the next line does the page move up a line - a
// short glide (SCROLL_GLIDE seconds) at the start of the new line, so the
// eye can follow it. Worked out from the playhead alone, so it holds after
// a jump or a repeat.
SCROLL_GLIDE :: 0.35

score_top :: proc() -> f32 {
	if !scrolling() do return f32(g.page * SCORE_SYSTEMS)
	st := f32(system_ticks())
	pos := max(g.scroll_view, 0) / st
	line := math.floor(pos)
	top := line
	if line >= 1 {
		glide := f32(SCROLL_GLIDE / music.tick_seconds(&g.song)) / st // in lines
		t := clamp((pos - line) / max(glide, 1e-4), 0, 1)
		t = t * t * (3 - 2 * t) // ease in and out
		top = line - 1 + t
	}
	return clamp(top, 0, max(f32(score_systems()) - 1, 0))
}

Staff :: struct {
	mid_y: f32, // the middle line
	mid:   int, // its step
	clef:  music.Clef,
	// Steps are written this many higher: a drum's rows (how bright it
	// is, not a pitch) are centred on the percussion staff.
	shift: int,
}

// One line of music as it is on screen.
Sys :: struct {
	index:   int,
	y0:      f32, // its band's top
	staves:  [2]Staff,
	n:       int, // 2: the grand staff (treble, bass)
	x0:      f32, // where the staff starts
	bars_x:  f32, // where its first bar starts
	bar_w:   f32,
	tick0:   i32,
	first:   i32, // its first bar
	n_bars:  i32, // bars of the song on it
	visible: bool,
}

score_sys :: proc(i: int, top: f32, clef: music.Clef) -> Sys {
	a := score_area()
	bps := score_bars_per_system()
	s := Sys{index = i}
	s.y0 = a.y + (f32(i) - top) * sys_h()
	s.visible = s.y0 + sys_h() > a.y && s.y0 < a.y + a.height
	s.first = i32(i) * bps
	s.n_bars = clamp(g.song.bars - s.first, 0, bps)
	s.tick0 = s.first * music.bar_ticks(&g.song)
	s.x0 = a.x + SCORE_ML
	s.bars_x = s.x0 + score_header_w(i == 0)
	s.bar_w = (a.x + a.width - SCORE_MR - s.bars_x) / f32(bps)
	// The staff a little below the band's middle: the bar number and the
	// notes above the staff get the room over it.
	cy := s.y0 + sys_h() * 0.52
	if clef == .Grand {
		s.n = 2
		off := GRAND_GAP / 2 + 2 * SP
		s.staves[0] = {cy - off, music.clef_mid(.Treble), .Treble, 0}
		s.staves[1] = {cy + off, music.clef_mid(.Bass), .Bass, 0}
	} else {
		s.n = 1
		s.staves[0] = {cy, music.clef_mid(clef), clef, 0}
		if clef == .Percussion {
			if t := active_track(); t != nil {
				ins := inst_of(t)
				lo := int(music.pitch_from_midi(int(ins.lo), 0).step)
				hi := int(music.pitch_from_midi(int(ins.hi), 0).step)
				s.staves[0].shift = s.staves[0].mid - (lo + hi) / 2
			}
		}
	}
	return s
}

step_y :: proc(st: Staff, step: int) -> f32 {
	return st.mid_y - f32(step - st.mid) * SP / 2
}

// Which staff of the line a step is written on.
staff_of :: proc(s: ^Sys, step: int) -> int {
	return s.n == 2 && step < MIDDLE_C ? 1 : 0
}

// Where in a line a (fractional) tick is.
score_x :: proc(s: ^Sys, tick: f32) -> f32 {
	bt := f32(music.bar_ticks(&g.song))
	rel := tick - f32(s.tick0)
	bar := math.floor(rel / bt)
	frac := (rel - bar * bt) / bt
	bx := s.bars_x + bar * s.bar_w
	return bx + BAR_PAD_L + frac * (s.bar_w - BAR_PAD_L - BAR_PAD_R)
}

score_staff_top :: proc(s: ^Sys) -> f32 {return s.staves[0].mid_y - 2 * SP}
score_staff_bottom :: proc(s: ^Sys) -> f32 {return s.staves[s.n - 1].mid_y + 2 * SP}

// The clef of every line: the instrument's first choice to begin with, and
// then, line by line, the clef the last line was on if this line's notes fit
// it with two ledger lines or fewer - else whichever of its clefs needs the
// fewest (the earlier in its list on a tie), as a cellist goes up into the
// tenor clef and on into the treble.
score_clefs :: proc() -> []music.Clef {
	n := score_systems()
	out := make([]music.Clef, n, context.temp_allocator)
	t := active_track()
	if t == nil {
		for &c in out do c = .Treble
		return out
	}
	cands := music.inst_clefs(inst_of(t))
	if cands[0] == .Grand {
		for &c in out do c = .Grand
		return out
	}
	lo := make([]int, n, context.temp_allocator)
	hi := make([]int, n, context.temp_allocator)
	for i in 0 ..< n {lo[i] = 1000; hi[i] = -1000}
	st := system_ticks()
	for note in t.notes {
		first := int(note.tick / st)
		last := int((note.tick + max(note.len, 1) - 1) / st)
		for i in max(first, 0) ..= min(last, n - 1) {
			lo[i] = min(lo[i], int(note.pitch.step))
			hi[i] = max(hi[i], int(note.pitch.step))
		}
	}
	ledgers :: proc(c: music.Clef, lo, hi: int) -> int {
		mid := music.clef_mid(c)
		return max(max((hi - (mid + 4)) / 2, 0), max(((mid - 4) - lo) / 2, 0))
	}
	prev := cands[0]
	for i in 0 ..< n {
		if hi[i] < lo[i] {out[i] = prev; continue}
		if ledgers(prev, lo[i], hi[i]) <= 2 {out[i] = prev; continue}
		best, best_l := cands[0], 1000
		for c in cands {
			l := ledgers(c, lo[i], hi[i])
			if l < best_l {best, best_l = c, l}
		}
		out[i] = best
		prev = best
	}
	return out
}

// What is under the mouse, as the grid's Hover: the staff position is the
// step, the place across the bar the time.
score_hover :: proc() -> Hover {
	m := g.ui.mouse
	a := score_area()
	if !rl.CheckCollisionPointRec(m, a) do return {}
	top := score_top()
	i := int(math.floor(top + (m.y - a.y) / sys_h()))
	if i < 0 || i >= score_systems() do return {}
	clefs := score_clefs()
	s := score_sys(i, top, clefs[i])
	if m.x < s.bars_x || m.x >= s.bars_x + f32(s.n_bars) * s.bar_w do return {}
	bt := music.bar_ticks(&g.song)
	bar := i32((m.x - s.bars_x) / s.bar_w)
	bx := s.bars_x + f32(bar) * s.bar_w
	frac := clamp((m.x - bx - BAR_PAD_L) / (s.bar_w - BAR_PAD_L - BAR_PAD_R), 0, 0.999)
	raw := s.tick0 + bar * bt + i32(frac * f32(bt))
	k := 0
	if s.n == 2 && m.y > (s.staves[0].mid_y + s.staves[1].mid_y) / 2 do k = 1
	st := s.staves[k]
	step := st.mid + int(math.round((st.mid_y - m.y) / (SP / 2))) - st.shift
	if s.n == 2 {
		if k == 0 do step = max(step, MIDDLE_C)
		else do step = min(step, MIDDLE_C - 1)
	}
	step = clamp(step, music.STEP_LO, music.STEP_HI)
	return {ok = true, step = step, raw_tick = raw, tick = snap_tick(raw)}
}

// Where a (fractional) tick and step are on screen, if their line is.
score_point :: proc(tick: f32, step: int, top: f32, clefs: []music.Clef) -> (x, y: f32, line: int, ok: bool) {
	i := int(tick / f32(system_ticks()))
	if i < 0 || i >= len(clefs) do return
	s := score_sys(i, top, clefs[i])
	if !s.visible do return
	st := s.staves[staff_of(&s, step)]
	return score_x(&s, tick), step_y(st, step + st.shift), i, true
}

// ---------------------------------------------------------------------------
// Writing a bar: which note values, ties, rests, accidentals
// ---------------------------------------------------------------------------

// A written duration: `value` the plain note (96 whole .. 3 thirty-second),
// dotted or a triplet's.
Dur :: struct {
	ticks, value, dots: i32,
	trip:               bool,
}

PLAIN_DURS := [?]Dur{{144, 96, 1, false}, {96, 96, 0, false}, {72, 48, 1, false}, {48, 48, 0, false}, {36, 24, 1, false}, {24, 24, 0, false}, {18, 12, 1, false}, {12, 12, 0, false}, {9, 6, 1, false}, {6, 6, 0, false}, {3, 3, 0, false}}
TRIP_DURS := [?]Dur{{64, 96, 0, true}, {32, 48, 0, true}, {16, 24, 0, true}, {8, 12, 0, true}, {4, 6, 0, true}, {2, 3, 0, true}}

// A length as written note values, longest first: 36 is a dotted quarter;
// 60 a half tied to an eighth; 16 a quarter-note triplet.
split_dur :: proc(len_: i32, out: ^[dynamic]Dur) {
	rem := len_
	for rem > 0 {
		if rem % 3 != 0 {
			found := false
			for d in TRIP_DURS do if d.ticks <= rem && (rem - d.ticks) % 3 == 0 {append(out, d); rem -= d.ticks; found = true; break}
			if !found do for d in TRIP_DURS do if d.ticks <= rem {append(out, d); rem -= d.ticks; found = true; break}
			if !found {append(out, Dur{rem, 3, 0, true}); rem = 0}
			continue
		}
		for d in PLAIN_DURS do if d.ticks <= rem {append(out, d); rem -= d.ticks; break}
	}
}

// A gap as rests: each the longest that starts on a multiple of its own
// length (a half rest on beat 1 or 3, a quarter on a beat), as rests are
// written.
split_rest :: proc(pos, len_: i32, out: ^[dynamic]Dur) {
	p, rem := pos, len_
	for rem > 0 {
		found := false
		if rem % 3 == 0 {
			for v in ([6]i32{96, 48, 24, 12, 6, 3}) do if v <= rem && p % v == 0 {append(out, Dur{v, v, 0, false}); p += v; rem -= v; found = true; break}
			if !found do for v in ([6]i32{96, 48, 24, 12, 6, 3}) do if v <= rem {append(out, Dur{v, v, 0, false}); p += v; rem -= v; found = true; break}
		} else {
			for d in TRIP_DURS do if d.ticks <= rem && (rem - d.ticks) % 3 == 0 {append(out, d); p += d.ticks; rem -= d.ticks; found = true; break}
			if !found do for d in TRIP_DURS do if d.ticks <= rem {append(out, d); p += d.ticks; rem -= d.ticks; found = true; break}
		}
		if !found {append(out, Dur{rem, 3, 0, true}); rem = 0}
	}
}

Head :: struct {
	step:     int,
	alter:    i8,
	show_acc: bool,
	note:     int, // index in the layer
	tie_in:   bool, // held on from the piece before (no accidental, no new sound)
	tie_out:  bool, // held on into the next
	shifted:  bool, // on the other side of the stem (a second in a chord)
	x, y:     f32,
}

// A chord or a rest, in one staff of one bar.
Ev :: struct {
	tick:     i32,
	using dur: Dur,
	rest:     bool,
	bar_rest: bool, // the whole bar empty: a whole rest in its middle
	staff:    int,
	heads:    [MAX_HEADS]Head,
	n:        int,
	x:        f32, // the heads' column
	up:       bool,
	stem_x:   f32,
	stem_end: f32,
	levels:   int, // flags or beams: 1 for an eighth
	beam:     int, // the beam group it is in; -1 none
}

levels_of :: proc(value: i32) -> int {
	switch {
	case value >= 24:
		return 0
	case value >= 12:
		return 1
	case value >= 6:
		return 2
	}
	return 3
}

// How long a note is WRITTEN: as long as it plays - unless it stops a
// little short of the next note (a fife's 10-tick eighths, played detached),
// when it is written up to that note, as a player's part would be: an
// eighth, not a triplet and a sliver of rest. "A little": a third of its
// length or less (never across a bar line it did not cross).
//
// A drum's strokes (the percussion clef) are written by when they fall, not
// how long they ring: each lasts until the next stroke, a quarter at most;
// and a stroke a tick or two before the next (a flam, a drag) is a grace
// note, not written (0).
written_len :: proc(t: ^music.Track, i: int, bar_end: i32, perc := false) -> i32 {
	n := t.notes[i]
	next := i32(-1)
	for j in i + 1 ..< len(t.notes) {
		if t.notes[j].tick > n.tick {next = t.notes[j].tick; break}
	}
	if perc {
		if next >= 0 && next - n.tick <= 2 && n.len <= 3 do return 0
		// The next stroke that is not a grace note.
		for j in i + 1 ..< len(t.notes) {
			m := t.notes[j]
			if m.tick <= n.tick do continue
			after := i32(-1)
			for k in j + 1 ..< len(t.notes) do if t.notes[k].tick > m.tick {after = t.notes[k].tick; break}
			if after >= 0 && after - m.tick <= 2 && m.len <= 3 do continue
			next = m.tick
			break
		}
		w := next >= 0 ? min(next - n.tick, 24) : max(n.len, 6)
		w = min(w, bar_end - n.tick)
		return max(w, 1)
	}
	end := n.tick + n.len
	target := next
	if next < 0 {
		// The last note: up to the next whole value it is short of.
		for d in PLAIN_DURS do if d.ticks >= n.len && d.ticks - n.len <= max(n.len / 3, 1) {target = n.tick + d.ticks}
		if target < 0 do return n.len
	}
	gap := target - end
	if gap <= 0 || gap > max(n.len / 3, 1) do return n.len
	if end <= bar_end && target > bar_end do return n.len
	return target - n.tick
}

// The bar's chords and rests for the layer, staff by staff, in time order.
score_bar :: proc(t: ^music.Track, bar: i32, s: ^Sys, out: ^[dynamic]Ev) {
	clear(out)
	bt := music.bar_ticks(&g.song)
	bs, be := bar * bt, (bar + 1) * bt
	durs := make([dynamic]Dur, context.temp_allocator)
	// A note struck while one is still sounding on the same line (a drum's
	// flam, a roll's extra stroke) is not written: its rhythm is the other's.
	busy: [music.STEP_HI + 1][2]i32 // start, end of the last note on each step
	for n, i in t.notes {
		if n.tick >= be do break
		st_ := int(n.pitch.step)
		if st_ >= 0 && st_ <= music.STEP_HI {
			b_ := busy[st_]
			if n.tick > b_[0] && n.tick < b_[1] do continue
			busy[st_] = {n.tick, n.tick + n.len}
		}
		if n.tick + n.len + n.len / 3 + 1 <= bs do continue
		wl := written_len(t, i, (n.tick / bt + 1) * bt, s.staves[0].clef == .Percussion)
		if wl == 0 || n.tick + wl <= bs do continue
		a, b := max(n.tick, bs), min(n.tick + wl, be)
		staff := staff_of(s, int(n.pitch.step))
		clear(&durs)
		split_dur(b - a, &durs)
		pos := a
		for d, k in durs {
			h := Head {
				step    = int(n.pitch.step),
				alter   = n.pitch.alter,
				note    = i,
				tie_in  = k > 0 || n.tick < bs,
				tie_out = k < len(durs) - 1 || n.tick + wl > be,
			}
			// Into a chord already there (same start, same written value).
			found := false
			for &e in out {
				if e.tick == pos && e.staff == staff && e.dur == d && !e.rest && e.n < MAX_HEADS {
					e.heads[e.n] = h
					e.n += 1
					found = true
					break
				}
			}
			if !found {
				e := Ev{tick = pos, dur = d, staff = staff, n = 1, beam = -1}
				e.heads[0] = h
				append(out, e)
			}
			pos += d.ticks
		}
	}
	// The rests: wherever nothing sounds, staff by staff.
	for staff in 0 ..< s.n {
		covered := make([dynamic][2]i32, context.temp_allocator)
		for e in out do if e.staff == staff do append(&covered, [2]i32{e.tick, e.tick + e.ticks})
		if len(covered) == 0 {
			append(out, Ev{tick = bs, dur = {bt, 96, 0, false}, rest = true, bar_rest = true, staff = staff, beam = -1})
			continue
		}
		// Sort by start (few enough for insertion).
		for i in 1 ..< len(covered) {
			for j := i; j > 0 && covered[j][0] < covered[j - 1][0]; j -= 1 do covered[j], covered[j - 1] = covered[j - 1], covered[j]
		}
		at := bs
		gap :: proc(from, to, bs: i32, staff: int, out: ^[dynamic]Ev) {
			if to <= from do return
			rd := make([dynamic]Dur, context.temp_allocator)
			split_rest(from - bs, to - from, &rd)
			p := from
			for d in rd {
				append(out, Ev{tick = p, dur = d, rest = true, staff = staff, beam = -1})
				p += d.ticks
			}
		}
		for c in covered {
			gap(at, c[0], bs, staff, out)
			at = max(at, c[1])
		}
		gap(at, be, bs, staff, out)
	}
	// Time order (stable: staff order kept within a tick).
	for i in 1 ..< len(out) {
		for j := i; j > 0 && out[j].tick < out[j - 1].tick; j -= 1 do out[j], out[j - 1] = out[j - 1], out[j]
	}
	// Each chord's heads bottom up.
	for &e in out {
		for i in 1 ..< e.n {
			for j := i; j > 0 && e.heads[j].step < e.heads[j - 1].step; j -= 1 do e.heads[j], e.heads[j - 1] = e.heads[j - 1], e.heads[j]
		}
		e.levels = e.rest ? 0 : levels_of(e.value)
	}
	// Accidentals: shown where a note differs from what the key signature,
	// or an earlier note in the bar on the same line or space, has made it.
	state: [music.STEP_HI + 1]i8
	for st in 0 ..= music.STEP_HI do state[st] = i8(music.key_alter(int(g.song.key), st))
	for &e in out {
		if e.rest do continue
		for &h in e.heads[:e.n] {
			if h.tie_in do continue
			if h.alter != state[h.step] {
				h.show_acc = true
				state[h.step] = h.alter
			}
		}
		// From here on, steps are where the heads are written.
		if sh := s.staves[e.staff].shift; sh != 0 {
			for &h in e.heads[:e.n] {h.step += sh; h.show_acc = false}
		}
	}
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

// The page, straight onto the window at its own resolution (window.odin):
// the paper, then everything on it, kept inside the sheet's area.
score_draw :: proc() {
	a := score_area()
	ink := score_ink()
	rl.DrawRectangleRec(a, ink.paper)
	sc := g.scale
	rl.BeginScissorMode(i32(a.x * sc), i32(a.y * sc), i32(a.width * sc + 0.5), i32(a.height * sc + 0.5))
	score_draw_page(ink)
	rl.EndScissorMode()
}

// A tie from one head to the next, or to or from a line's edge.
Tie_End :: struct {
	note:     int,
	tick:     i32,
	x, y:     f32,
	up:       bool, // the stem's side: the tie curves the other way
	tie_in:   bool,
	tie_out:  bool,
	line:     int,
	left:     f32, // the line's first bar's start
	right:    f32, // the line's end
	col:      rl.Color,
}

@(private = "file")
score_draw_page :: proc(ink: Score_Ink) {
	t := active_track()
	top := score_top()
	clefs := score_clefs()
	first := max(int(math.floor(top)), 0)
	last := min(int(top) + SCORE_SYSTEMS, score_systems() - 1)
	playing_tick := g.player.playing ? player_tick(&g.player, &g.song) : -1
	trail: [TRAIL_CAP]Tracked
	n_trail := 0
	if g.helper do n_trail = fb_current_trail(trail[:])
	ties := make([dynamic]Tie_End, context.temp_allocator)
	evs := make([dynamic]Ev, context.temp_allocator)

	for i in first ..= last {
		s := score_sys(i, top, clefs[i])
		if !s.visible do continue
		sys_frame_draw(&s, ink)
		if t == nil do continue
		for b in 0 ..< s.n_bars {
			score_bar(t, s.first + b, &s, &evs)
			bar_draw(t, &s, evs[:], ink, playing_tick, trail[:n_trail], &ties)
		}
	}
	ties_draw(ties[:], ink)
	if title_room(top) do text_centered(g.song.title, {score_area().x, score_area().y + 4, score_area().width, 12}, ink.faint)

	// The row the Helper's board or keyboard is pointing at, on every line.
	if g.helper && overlay_none() {
		m := -1
		if kb_board() != nil do m = kb_hover()
		if fb_board() != nil {
			if fh := fb_hover(); fh.ok do m = fb_midi(fh)
		}
		if m >= 0 {
			step := int(music.pitch_from_midi(m, fb_spell_key()).step)
			for i in first ..= last {
				s := score_sys(i, top, clefs[i])
				if !s.visible || s.n_bars == 0 do continue
				sst := s.staves[staff_of(&s, step)]
				y := step_y(sst, step + sst.shift)
				rl.DrawRectangleRec({s.x0, y - SP / 4, s.bars_x + f32(s.n_bars) * s.bar_w - s.x0, SP / 2}, with_alpha(ink.accent, 50))
			}
		}
	}

	markers_draw(top, clefs, ink, playing_tick)
	ghost_draw(t, top, clefs, ink)
	// What the microphone hears (input.odin).
	input_sheet_draw()
}

@(private = "file")
title_room :: proc(top: f32) -> bool {
	return top < 0.01 && len(g.song.title) > 0
}

// Staff lines, clef, key and time signatures, bar lines, the bar number.
@(private = "file")
sys_frame_draw :: proc(s: ^Sys, ink: Score_Ink) {
	if s.n_bars == 0 do return
	x1 := s.bars_x + f32(s.n_bars) * s.bar_w
	for k in 0 ..< s.n {
		st := s.staves[k]
		for l in -2 ..= 2 {
			y := st.mid_y + f32(l) * SP
			rl.DrawLineEx({s.x0, y}, {x1, y}, 1, ink.line)
		}
		clef_draw(st, s.x0 + 0.7 * SP, ink.ink)
		// The key signature.
		key := int(g.song.key)
		kx := s.x0 + KEY_X
		sharp_order := [7]int{3, 0, 4, 1, 5, 2, 6} // F C G D A E B
		flat_order := [7]int{6, 2, 5, 1, 4, 0, 3} // B E A D G C F
		for j in 0 ..< (st.clef == .Percussion ? 0 : abs(key)) {
			letter := key > 0 ? sharp_order[j] : flat_order[j]
			low := st.mid + (key > 0 ? music.clef_sharp_low(st.clef) : music.clef_flat_low(st.clef))
			step := low + ((letter - low % 7) + 14) % 7
			accidental_draw(key > 0 ? 1 : -1, kx + f32(j) * KEY_STEP, step_y(st, step), SP, ink.ink)
		}
		// The time signature, on the song's first line.
		if s.index == 0 {
			tx := s.bars_x - TIME_W / 2 - 0.3 * SP // the digits' middle
			for num, r in ([2]i32{g.song.beats, g.song.beat_unit}) {
				str := fmt.tprintf("%d", num)
				cy := st.mid_y + (r == 0 ? -SP : SP)
				w := text_width(str, 20)
				for dx in ([2]f32{0, 0.5}) do text(str, tx + dx - w / 2, cy - 9, ink.ink, 20)
			}
		}
	}
	top_y, bot_y := score_staff_top(s), score_staff_bottom(s)
	// The line's start: a line down all its staves; the grand staff braced.
	rl.DrawLineEx({s.x0, top_y}, {s.x0, bot_y}, 1, ink.line)
	if s.n == 2 do brace_draw(s.x0 - 0.5 * SP, top_y, bot_y, ink.ink)
	// Bar lines; after the song's last bar, the final double bar.
	for b in 1 ..= s.n_bars {
		x := s.bars_x + f32(b) * s.bar_w
		if s.first + b == g.song.bars {
			rl.DrawLineEx({x - 0.75 * SP, top_y}, {x - 0.75 * SP, bot_y}, 1, ink.line)
			rl.DrawRectangleRec({x - 0.45 * SP, top_y, 0.45 * SP, bot_y - top_y}, ink.ink)
		} else {
			rl.DrawLineEx({x, top_y}, {x, bot_y}, 1, ink.line)
		}
	}
	// The bar number over the line's first bar (not on the very first line).
	if s.index > 0 do text(fmt.tprintf("%d", s.first + 1), s.x0, top_y - 2.2 * SP - 6, ink.faint)
}

@(private = "file")
clef_draw :: proc(st: Staff, x: f32, col: rl.Color) {
	y := st.mid_y
	switch st.clef {
	case .Treble, .Treble_8vb, .Treble_8va, .Grand:
		glyph_draw(clef_glyph(.G), x + 0.55 * SP, y, SP, col)
		if st.clef == .Treble_8vb do text("8", x + 0.75 * SP, y + 3.6 * SP, col)
		if st.clef == .Treble_8va do text("8", x + 0.55 * SP, y - 4.9 * SP, col)
	case .Bass, .Bass_8vb:
		glyph_draw(clef_glyph(.F), x, y, SP, col)
		if st.clef == .Bass_8vb do text("8", x + 0.5 * SP, y + 2.3 * SP, col)
	case .Alto:
		glyph_draw(clef_glyph(.C), x, y, SP, col)
	case .Tenor:
		glyph_draw(clef_glyph(.C), x, y - SP, SP, col) // on the fourth line
	case .Percussion:
		glyph_draw(clef_glyph(.Perc), x, y, SP, col)
	}
}

@(private = "file")
brace_draw :: proc(x, y0, y1: f32, col: rl.Color) {
	h := (y1 - y0) / SP // in spaces
	// Two strokes meeting at a point in the middle, thick in each half.
	upper := [?]Pen{{0.1, 0, 0.08}, {-0.55, -0.12 * h, 0.4}, {-0.5, -0.36 * h, 0.5}, {-1.0, -0.5 * h, 0.08}}
	lower := [?]Pen{{-1.0, -0.5 * h, 0.08}, {-0.5, -0.64 * h, 0.5}, {-0.55, -0.88 * h, 0.4}, {0.1, -h, 0.08}}
	pen_stroke(upper[:], x, y0, SP, col)
	pen_stroke(lower[:], x, y0, SP, col)
}

@(private = "file")
bar_draw :: proc(t: ^music.Track, s: ^Sys, evs: []Ev, ink: Score_Ink, playing_tick: i32, trail: []Tracked, ties: ^[dynamic]Tie_End) {
	bt := music.bar_ticks(&g.song)
	bar := evs[0].tick / bt if len(evs) > 0 else 0
	bs := bar * bt
	muted := !music.track_audible(&g.song, t)
	// Beams: eighths and shorter, in one staff, within a beat (three eighths
	// in 6/8, 9/8, 12/8), with no rest between.
	span := music.beat_ticks(&g.song)
	if g.song.beat_unit == 8 && g.song.beats % 3 == 0 do span = 3 * span
	group := 0
	close_run :: proc(evs: []Ev, run: ^[dynamic]int, group: ^int) {
		if len(run) >= 2 {
			for i in run do evs[i].beam = group^
			group^ += 1
		}
		clear(run)
	}
	run := make([dynamic]int, context.temp_allocator)
	for staff in 0 ..< s.n {
		window := i32(-1)
		for i in 0 ..< len(evs) {
			e := &evs[i]
			if e.staff != staff do continue
			beamable := !e.rest && e.levels > 0
			w := (e.tick - bs) / span
			if beamable && len(run) > 0 && w == window {
				append(&run, i)
				continue
			}
			close_run(evs, &run, &group)
			if beamable {
				append(&run, i)
				window = w
			}
		}
		close_run(evs, &run, &group)
	}

	// Stems: a chord's direction from its note furthest from the middle
	// line (the middle line itself: down); a beamed group's from its
	// furthest note of all.
	for &e in evs {
		if e.rest do continue
		st := s.staves[e.staff]
		e.x = score_x(s, f32(e.tick)) + HEAD_RX
		lo, hi := e.heads[0].step, e.heads[e.n - 1].step
		e.up = (hi - st.mid) + (lo - st.mid) < 0
	}
	for gi in 0 ..< group {
		far, far_d := 0, -1
		for &e in evs do if e.beam == gi {
			st := s.staves[e.staff]
			for h in e.heads[:e.n] do if abs(h.step - st.mid) > far_d {far_d = abs(h.step - st.mid); far = h.step - st.mid}
		}
		for &e in evs do if e.beam == gi do e.up = far < 0
	}
	// Heads: seconds in a chord put on the other side of the stem.
	for &e in evs {
		if e.rest do continue
		st := s.staves[e.staff]
		if e.up {
			for i in 1 ..< e.n do if e.heads[i].step - e.heads[i - 1].step == 1 && !e.heads[i - 1].shifted do e.heads[i].shifted = true
		} else {
			for i := e.n - 2; i >= 0; i -= 1 do if e.heads[i + 1].step - e.heads[i].step == 1 && !e.heads[i + 1].shifted do e.heads[i].shifted = true
		}
		for &h in e.heads[:e.n] {
			h.x = e.x
			if h.shifted do h.x += e.up ? 2 * HEAD_RX - 1 : -(2 * HEAD_RX - 1)
			h.y = step_y(st, h.step)
		}
		e.stem_x = e.up ? e.x + HEAD_RX - 0.6 : e.x - HEAD_RX + 0.6
		extra := f32(max(e.levels - 1, 0)) * 0.5 * SP
		if e.up do e.stem_end = min(e.heads[e.n - 1].y - STEM_LEN - extra, st.mid_y)
		else do e.stem_end = max(e.heads[0].y + STEM_LEN + extra, st.mid_y)
	}
	// Beamed stems end on one straight beam, sloping with the tune but by
	// no more than a space, and no stem shorter than it would be alone.
	for gi in 0 ..< group {
		a, b := -1, -1
		for e, i in evs do if e.beam == gi {if a < 0 do a = i; b = i}
		ea, eb := &evs[a], &evs[b]
		dx := max(eb.stem_x - ea.stem_x, 1)
		dy := clamp(eb.stem_end - ea.stem_end, -SP, SP)
		slope := dy / dx
		up := ea.up
		shift := f32(0)
		for &e in evs do if e.beam == gi {
			y := ea.stem_end + slope * (e.stem_x - ea.stem_x)
			if up do shift = min(shift, e.stem_end - y)
			else do shift = max(shift, e.stem_end - y)
		}
		for &e in evs do if e.beam == gi do e.stem_end = ea.stem_end + shift + slope * (e.stem_x - ea.stem_x)
	}

	// Now draw.
	for &e, ei in evs {
		st := s.staves[e.staff]
		if e.rest {
			x := e.bar_rest ? s.bars_x + f32(bar - s.first) * s.bar_w + s.bar_w / 2 : score_x(s, f32(e.tick)) + 0.6 * SP
			rest_draw(e.value, x, st.mid_y, SP, ink.ink)
			if e.dots > 0 do rl.DrawCircleV({x + 1.1 * SP, st.mid_y - 0.5 * SP}, 0.18 * SP, ink.ink)
			continue
		}
		// Each head's colour: as the grid's notes.
		cols: [MAX_HEADS]rl.Color
		for h, k in e.heads[:e.n] do cols[k] = head_colour(t, h.note, ink, muted, playing_tick, trail)
		stem_col := cols[0]
		for k in 1 ..< e.n do if cols[k] != stem_col do stem_col = ink.ink

		// Ledger lines, as far as the furthest head either side.
		for h in e.heads[:e.n] {
			off := h.step - st.mid
			if abs(off) < 6 do continue
			dir := off > 0 ? 1 : -1
			for l := 6; l <= abs(off); l += 2 {
				y := step_y(st, st.mid + dir * l)
				rl.DrawLineEx({h.x - HEAD_RX - 0.4 * SP, y}, {h.x + HEAD_RX + 0.4 * SP, y}, 1, ink.line)
			}
		}
		// Heads: filled to the quarter, open for halves and wholes.
		for h, k in e.heads[:e.n] {
			c := cols[k]
			if e.value >= 96 {
				ellipse_ring({h.x, h.y}, HEAD_RX * 1.25, HEAD_RY * 1.05, 0, HEAD_RX * 0.55, HEAD_RY * 0.7, 60, c)
			} else if e.value >= 48 {
				ellipse_ring({h.x, h.y}, HEAD_RX, HEAD_RY, HEAD_ANGLE, HEAD_RX * 0.8, HEAD_RY * 0.42, HEAD_ANGLE, c)
			} else {
				ellipse_fill({h.x, h.y}, HEAD_RX, HEAD_RY, HEAD_ANGLE, c)
			}
			// Selected: a box round it; check mode: how it was played.
			if h.note == g.selected do outline(rect(h.x - HEAD_RX - 3, h.y - HEAD_RY - 3, 2 * HEAD_RX + 6, 2 * HEAD_RY + 6), ink.accent)
			if cc, final, ok := check_colour(t.notes[h.note].tick, music.pitch_midi(t.notes[h.note].pitch)); ok && !h.tie_in {
				r := rect(h.x - HEAD_RX - 4, h.y - HEAD_RY - 4, 2 * HEAD_RX + 8, 2 * HEAD_RY + 8)
				rl.DrawRectangleLinesEx(r, final ? 2 : 1, final ? cc : with_alpha(cc, 150))
			}
			// Dots: in the space, beside the head.
			for d in 0 ..< int(e.dots) {
				dy: f32 = (h.step - st.mid) % 2 == 0 ? -SP / 2 : 0
				rl.DrawCircleV({e.x + HEAD_RX + (0.7 + f32(d) * 0.6) * SP + (e.up && e.n > 1 ? HEAD_RX : 0), h.y + dy}, 0.18 * SP, c)
			}
			append(ties, Tie_End{note = h.note, tick = e.tick, x = h.x, y = h.y, up = e.up, tie_in = h.tie_in, tie_out = h.tie_out, line = s.index, left = s.bars_x, right = s.bars_x + f32(s.n_bars) * s.bar_w, col = c})
		}
		// Accidentals, to the left, in columns where they would collide.
		{
			col_top: [4]int = {1000, 1000, 1000, 1000}
			for k := e.n - 1; k >= 0; k -= 1 {
				h := e.heads[k]
				if !h.show_acc do continue
				c := 0
				for c < 3 && col_top[c] - h.step < 6 && col_top[c] != 1000 do c += 1
				col_top[c] = h.step
				left := e.x - HEAD_RX
				for hh in e.heads[:e.n] do left = min(left, hh.x - HEAD_RX)
				ax := left - 0.25 * SP - ACC_W * SP * f32(c + 1) - (h.alter == -2 ? ACC_W * SP : 0)
				accidental_draw(h.alter, ax, h.y, SP, cols[k])
			}
		}
		// Stem, and flags when not beamed.
		if e.value < 96 {
			y0 := e.up ? e.heads[0].y : e.heads[e.n - 1].y
			rl.DrawLineEx({e.stem_x, y0}, {e.stem_x, e.stem_end}, 1, stem_col)
			if e.beam < 0 && e.levels > 0 do flags_draw(e.levels, e.stem_x, e.stem_end, SP, e.up, stem_col)
		}
		// Beams: from each beamed chord to the next.
		if e.beam >= 0 {
			nx := -1
			for j in ei + 1 ..< len(evs) do if evs[j].beam == e.beam {nx = j; break}
			pv := -1
			for j := ei - 1; j >= 0; j -= 1 do if evs[j].beam == e.beam {pv = j; break}
			dir: f32 = e.up ? 1 : -1 // towards the heads
			for lv in 1 ..= e.levels {
				off := f32(lv - 1) * BEAM_GAP * dir
				if nx >= 0 && evs[nx].levels >= lv {
					f := &evs[nx]
					beam_quad(e.stem_x, e.stem_end + off, f.stem_x, f.stem_end + off, dir, ink.ink)
				} else if lv > 1 && (pv < 0 || evs[pv].levels < lv) {
					// A short stub: towards the next chord, or the last's
					// towards the one before.
					other := nx >= 0 ? &evs[nx] : &evs[pv]
					len_ := 1.1 * SP * (nx >= 0 ? 1 : -1)
					slope := (other.stem_end - e.stem_end) / (other.stem_x - e.stem_x)
					beam_quad(e.stem_x, e.stem_end + off, e.stem_x + len_, e.stem_end + off + slope * len_, dir, ink.ink)
				}
			}
		}
	}
	tuplets_draw(s, evs, ink)
}

@(private = "file")
beam_quad :: proc(x0, y0, x1, y1, dir: f32, col: rl.Color) {
	th := BEAM_TH * dir
	quad({x0, y0}, {x1, y1}, {x1, y1 + th}, {x0, y0 + th}, col)
}

// Triplets: a 3 over each run of triplet notes and rests that makes up two
// of its first value (three triplet eighths are two eighths' time).
@(private = "file")
tuplets_draw :: proc(s: ^Sys, evs: []Ev, ink: Score_Ink) {
	for staff in 0 ..< s.n {
		i := 0
		for i < len(evs) {
			e := evs[i]
			if e.staff != staff || !e.trip {i += 1; continue}
			total := i32(0)
			j := i
			top := f32(1e9)
			x0, x1 := f32(1e9), f32(-1e9)
			for j < len(evs) {
				f := evs[j]
				if f.staff != staff {j += 1; continue}
				if !f.trip do break
				total += f.ticks
				x := f.rest ? score_x(s, f32(f.tick)) + 0.6 * SP : f.x
				x0, x1 = min(x0, x), max(x1, x)
				if f.rest do top = min(top, s.staves[staff].mid_y - 2 * SP)
				else {
					top = min(top, f.heads[f.n - 1].y - HEAD_RY)
					if f.value < 96 do top = min(top, f.stem_end)
				}
				j += 1
				if total >= 2 * e.value do break
			}
			y := min(top, s.staves[staff].mid_y - 2 * SP) - 1.3 * SP
			mx := (x0 + x1) / 2
			rl.DrawLineEx({x0 - HEAD_RX, y + 4}, {x0 - HEAD_RX, y}, 1, ink.ink)
			rl.DrawLineEx({x0 - HEAD_RX, y}, {mx - 5, y}, 1, ink.ink)
			rl.DrawLineEx({mx + 5, y}, {x1 + HEAD_RX, y}, 1, ink.ink)
			rl.DrawLineEx({x1 + HEAD_RX, y}, {x1 + HEAD_RX, y + 4}, 1, ink.ink)
			text("3", mx - 2, y - 5, ink.ink)
			i = j
		}
	}
}

// The colour a note's head takes: the grid's rules, on paper.
@(private = "file")
head_colour :: proc(t: ^music.Track, i: int, ink: Score_Ink, muted: bool, playing_tick: i32, trail: []Tracked) -> rl.Color {
	n := t.notes[i]
	col := ink.ink
	if muted do col = ink.faint
	in_trail := false
	for tr in trail {
		if tr.index != i do continue
		col = colour_mix(ink.ink, track_colour(tr.step), trail_alpha(tr.rel))
		in_trail = true
		break
	}
	sounding := playing_tick >= n.tick && playing_tick < n.tick + n.len && !muted
	if sounding && !in_trail do col = ink.accent
	if !in_range(t.inst, n.pitch) do col = ink.bad
	if i == g.selected do col = ink.accent
	return col
}

@(private = "file")
ties_draw :: proc(ties: []Tie_End, ink: Score_Ink) {
	// In note order, then time: each piece next to the one it ties to.
	list := ties
	for i in 1 ..< len(list) {
		for j := i; j > 0; j -= 1 {
			a, b := list[j - 1], list[j]
			if a.note < b.note || (a.note == b.note && a.tick <= b.tick) do break
			list[j - 1], list[j] = b, a
		}
	}
	arc :: proc(x0, x1, y: f32, over: bool, col: rl.Color) {
		if x1 - x0 < 2 do return
		d: f32 = over ? 1 : -1 // up the page is +y in pen units
		h := clamp((x1 - x0) / SP * 0.12, 0.35, 0.8)
		pts := [3]Pen{{0, 0, 0.04}, {(x1 - x0) / SP / 2, d * h, 0.2}, {(x1 - x0) / SP, 0, 0.04}}
		pen_stroke(pts[:], x0, y, SP, col)
	}
	for e, i in list {
		over := !e.up
		y := e.y + (over ? -0.55 * SP : 0.55 * SP)
		if e.tie_out {
			if i + 1 < len(list) && list[i + 1].note == e.note && list[i + 1].tie_in && list[i + 1].line == e.line {
				arc(e.x + HEAD_RX * 0.6, list[i + 1].x - HEAD_RX * 0.6, y, over, e.col)
			} else {
				arc(e.x + HEAD_RX * 0.6, e.right - 2, y, over, e.col)
			}
		}
		if e.tie_in {
			if !(i > 0 && list[i - 1].note == e.note && list[i - 1].tie_out && list[i - 1].line == e.line) {
				arc(e.left + 2, e.x - HEAD_RX * 0.6, y, over, e.col)
			}
		}
	}
}

// Playhead, the bar cursor, where a Bar or Page play stops or repeats from.
@(private = "file")
markers_draw :: proc(top: f32, clefs: []music.Clef, ink: Score_Ink, playing_tick: i32) {
	vline :: proc(tick: f32, top: f32, clefs: []music.Clef, col: rl.Color, w: f32, tri_mark: bool) {
		i := int(tick / f32(system_ticks()))
		if i < 0 || i >= len(clefs) do return
		s := score_sys(i, top, clefs[i])
		if !s.visible || i32(tick) >= s.tick0 + s.n_bars * music.bar_ticks(&g.song) do return
		x := score_x(&s, tick)
		y0, y1 := score_staff_top(&s) - 1.5 * SP, score_staff_bottom(&s) + 1.5 * SP
		rl.DrawLineEx({x, y0}, {x, y1}, w, col)
		if tri_mark do rl.DrawTriangle({x - 5, y0 - 7}, {x, y0}, {x + 5, y0 - 7}, col)
	}
	if !g.player.playing {
		vline(f32(play_from()), top, clefs, with_alpha(ink.accent, 110), 2, true)
		return
	}
	now := scrolling() ? g.scroll_view : f32(playing_tick)
	vline(now, top, clefs, g.score_paper ? ink.accent : COL_MATCH, 2, false)
	p := &g.player
	end := p.stop_tick
	if p.loop do end = p.from_tick + p.loop_ticks
	if end > 0 do vline(f32(end) - 0.01, top, clefs, with_alpha(p.loop ? COL_GOOD : COL_BAD, 160), 2, false)
	if p.loop do vline(f32(p.from_tick), top, clefs, with_alpha(COL_GOOD, 160), 2, true)
}

// The note a click would place, faintly, with its ledger lines.
@(private = "file")
ghost_draw :: proc(t: ^music.Track, top: f32, clefs: []music.Clef, ink: Score_Ink) {
	if t == nil || g.drag.active || !overlay_none() do return
	hov := score_hover()
	if !hov.ok do return
	if music.track_note_at(t, hov.step, hov.raw_tick) >= 0 do return
	x, y, line, ok := score_point(f32(hov.tick), hov.step, top, clefs)
	if !ok do return
	p := placed_pitch(hov.step)
	col := with_alpha(ink.ink, 110)
	if !in_range(t.inst, p) do col = with_alpha(ink.bad, 160)
	s := score_sys(line, top, clefs[line])
	st := s.staves[staff_of(&s, hov.step)]
	hx := x + HEAD_RX
	off := hov.step + st.shift - st.mid
	dir := off > 0 ? 1 : -1
	for l := 6; l <= abs(off); l += 2 {
		ly := step_y(st, st.mid + dir * l)
		rl.DrawLineEx({hx - HEAD_RX - 0.4 * SP, ly}, {hx + HEAD_RX + 0.4 * SP, ly}, 1, col)
	}
	ellipse_fill({hx, y}, HEAD_RX, HEAD_RY, HEAD_ANGLE, col)
	if st.shift == 0 && p.alter != music.key_alter(int(g.song.key), hov.step) do accidental_draw(p.alter, hx - HEAD_RX - 0.25 * SP - ACC_W * SP, y, SP, col)
}
