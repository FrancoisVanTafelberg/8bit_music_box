package app

/*
    The Cello Fingerboard (Cello Helper only).

    The board as the player sees it looking down the neck: the nut at the top,
    the C string on the left, A on the right. Every place a finger can stop a
    string is a small circle, from the open string (above the nut) to the end
    of the fingerboard, FB_SEMIS semitones up. The circles are where the notes
    really are: each semitone is 2^(-1/12) of the string left, so they crowd
    together further down the board, as they do under the hand.

    What lights up:

      * the note under the mouse on the sheet (or the note a click there
        would place) - EVERY place it can be played, on every string;
      * the notes of the current layer that are sounding, while playing;
      * the selected note (a ring);
      * the circle under the mouse here, and every other place for that note.

    Click a circle to hear it. The key filter hides every position whose note
    is not in the chosen key (the lit ones above always show).
*/

import "core:fmt"
import "core:math"
import "music"
import rl "vendor:raylib"

// From the open string to the end of the fingerboard.
FB_SEMIS :: 29

// The panel, from here to the right edge of the screen (the sheet ends where
// it starts). Just wide enough for the board, the note names beside its
// circles, the octave marks to its left and the finger labels at the edge.
FB_X_CELLO :: 1280 - 348
FB_X :: FB_X_CELLO
FB_W :: 1280 - FB_X
FB_CX :: FB_X + 166 // the middle of the board

FB_OPEN_Y :: TOP_H + 208 // the open-string circles, above the nut
FB_NUT_Y :: TOP_H + 224
FB_END_Y :: 720 - STATUS_H - 12

FB_HALF_NUT :: 69 // half the board's width at the nut...
FB_HALF_END :: 93 // ...and at its end: a fingerboard widens toward the bridge

// Open strings, low to high = left to right.
FB_OPEN := [4]int{36, 43, 50, 57} // C2 G2 D3 A3
FB_STRING_NAME := [4]string{"C", "G", "D", "A"}

// The keys the filter offers, as key signatures (sharps +, flats -).
@(private = "file")
FB_KEYS_SHARP := [8]i8{0, 1, 2, 3, 4, 5, 6, 7}
@(private = "file")
FB_KEYS_FLAT := [7]i8{-1, -2, -3, -4, -5, -6, -7}

// Hand positions: where each finger stops the string, in semitones above the
// open string - the same on all four strings. Closed hand in the neck
// positions: the fingers a semitone apart, so 1 to 4 spans a minor third (in
// 1st position on the A string: B C C# D). "1st ext." is the forward
// extension, a whole tone between 1 and 2. From 5th position up the hand
// plays with three fingers; in thumb position the thumb (T) lies across the
// strings at the octave, and 1 2 3 play the notes above it.
Hand_Position :: struct {
	name:    string,
	short:   string, // for the button
	fingers: [4]i8, // f1..f4; 0 = not used in this position
	thumb:   i8, // 0 = no thumb on the string
}

HAND_POSITIONS := [?]Hand_Position {
	{"Half position", "1/2", {1, 2, 3, 4}, 0},
	{"1st position", "1st", {2, 3, 4, 5}, 0},
	{"1st position, extended", "1st x", {2, 4, 5, 6}, 0},
	{"Lower 2nd position", "2nd-", {3, 4, 5, 6}, 0},
	{"2nd position", "2nd", {4, 5, 6, 7}, 0},
	{"3rd position", "3rd", {5, 6, 7, 8}, 0},
	{"Upper 3rd position", "3rd+", {6, 7, 8, 9}, 0},
	{"4th position", "4th", {7, 8, 9, 10}, 0},
	{"5th position (three fingers)", "5th", {9, 10, 12, 0}, 0},
	{"1st thumb position", "Thumb", {14, 16, 17, 0}, 12},
}
HAND_DEFAULT :: 1 // 1st position

// One place on the board: a string, and how many semitones above open.
Fb_Pos :: struct {
	ok:     bool,
	string: int,
	semis:  int,
}

fb_midi :: proc(p: Fb_Pos) -> int {
	return FB_OPEN[p.string] + p.semis
}

// HOW MUCH OF THE BOARD IS SHOWN follows the hand position: from the nut to
// a little past the last finger (g.fb_view, in semitones, gliding to the new
// length when the position changes), so 1st position fills the panel and the
// notes are big. Never further than the thumb position's reach: past that,
// a player does not need this app.
FB_VIEW_MAX :: 20
FB_VIEW_MIN :: 7

fb_view_target :: proc() -> f32 {
	hand := &HAND_POSITIONS[clamp(int(g.fb_hand), 0, len(HAND_POSITIONS) - 1)]
	far := int(hand.thumb)
	for f in hand.fingers do far = max(far, int(f))
	return f32(clamp(far + 3, FB_VIEW_MIN, FB_VIEW_MAX))
}

fb_in_view :: proc(n: int) -> bool {
	return f32(n) <= g.fb_view + 0.01
}

// How far down the string semitone n is, 0 at the nut, 1 at the bridge.
@(private = "file")
fb_phys :: proc(n: f32) -> f32 {
	return 1 - math.pow(2, -n / 12)
}

// Where semitone `n` is stopped, as a fraction of the way down what is shown.
@(private = "file")
fb_frac :: proc(n: int) -> f32 {
	return fb_phys(f32(n)) / fb_phys(max(g.fb_view, 1))
}

fb_y :: proc(n: int) -> f32 {
	if n == 0 do return FB_OPEN_Y
	return FB_NUT_Y + fb_frac(n) * (FB_END_Y - FB_NUT_Y)
}

fb_center_x :: proc() -> f32 {
	return f32(FB_CX)
}

@(private = "file")
fb_half :: proc(y: f32) -> f32 {
	// The board widens along its real length: over the part shown, only a
	// share of the whole widening.
	t := clamp((y - FB_NUT_Y) / (FB_END_Y - FB_NUT_Y), 0, 1.1) * fb_phys(max(g.fb_view, 1)) / fb_phys(f32(FB_SEMIS))
	return FB_HALF_NUT + (FB_HALF_END - FB_HALF_NUT) * t
}

fb_x :: proc(s: int, y: f32) -> f32 {
	return fb_center_x() + (f32(s) * 2 - 3) / 4 * fb_half(y) * 1.5
}

// How big a circle can be here without touching its neighbours.
@(private = "file")
fb_radius :: proc(n: int) -> f32 {
	if n == 0 do return 6.5
	gap := fb_y(n + 1) - fb_y(n)
	return clamp(gap * 0.42, 3, 8.5)
}

// The circle under the mouse, if any.
fb_hover :: proc() -> Fb_Pos {
	m := g.ui.mouse
	if m.x < FB_X || m.y < FB_OPEN_Y - 10 || m.y > FB_END_Y + 10 do return {}
	best: Fb_Pos
	best_d := f32(1e9)
	for s in 0 ..< 4 {
		for n in 0 ..= FB_SEMIS {
			if !fb_in_view(n) do break
			if !fb_visible(FB_OPEN[s] + n) do continue
			y := fb_y(n)
			dx, dy := m.x - fb_x(s, y), m.y - y
			d := dx * dx + dy * dy
			r := fb_radius(n) + 3
			if d <= r * r && d < best_d {
				best = {true, s, n}
				best_d = d
			}
		}
	}
	return best
}

// Is this note in the filter's key (or is there no filter)?
fb_in_key :: proc(midi: int) -> bool {
	if !g.fb_filter do return true
	return in_key(midi, int(g.fb_key))
}

in_key :: proc(midi, key: int) -> bool {
	tonic := ((7 * key) % 12 + 12) % 12
	switch (midi % 12 - tonic + 12) % 12 {
	case 0, 2, 4, 5, 7, 9, 11:
		return true
	}
	return false
}

@(private = "file")
fb_visible :: proc(midi: int) -> bool {
	return fb_in_key(midi)
}

// How a note is spelled on the board: in the filter's key, else the song's.
fb_spell_key :: proc() -> int {
	return g.fb_filter ? int(g.fb_key) : int(g.song.key)
}

fb_name :: proc(midi: int) -> string {
	return music.pitch_name_temp(music.pitch_from_midi(midi, fb_spell_key()))
}

// The cello the active layer plays (the one clicks are heard on).
@(private = "file")
fb_cello :: proc() -> ^music.Instrument {
	if t := active_track(); t != nil do return inst_of(t)
	if id, ok := music.inst_find(&g.song, CELLO_KEY); ok do return music.inst_get(&g.song, id)
	return nil
}

@(private = "file")
fb_playable :: proc(midi: int) -> bool {
	ins := fb_cello()
	return ins != nil && i32(midi) >= ins.lo && i32(midi) <= ins.hi
}

// The note the sheet is pointing at: the note under the mouse, or the one a
// click there would place. -1 for none.
fb_sheet_target :: proc() -> int {
	hov := sheet_hover()
	if !hov.ok || !overlay_none() do return -1
	if t := active_track(); t != nil {
		if i := music.track_note_at(t, hov.step, hov.raw_tick); i >= 0 do return music.pitch_midi(t.notes[i].pitch)
	}
	return music.pitch_midi(placed_pitch(hov.step))
}

// "D string +7, G string +14, C string +21"
fb_places :: proc(midi: int) -> string {
	s := ""
	for st := 3; st >= 0; st -= 1 {
		n := midi - FB_OPEN[st]
		if n < 0 || n > FB_SEMIS do continue
		one := n == 0 ? fmt.tprintf("open %s string", FB_STRING_NAME[st]) : fmt.tprintf("%s string +%d", FB_STRING_NAME[st], n)
		s = len(s) == 0 ? one : fmt.tprintf("%s, %s", s, one)
	}
	return len(s) == 0 ? "not on the fingerboard" : s
}

// ---------------------------------------------------------------------------

fingerboard_draw :: proc() {
	// Glide to the hand position's length of board.
	{
		target := fb_view_target()
		if g.fb_view <= 0 do g.fb_view = target
		g.fb_view += (target - g.fb_view) * min(rl.GetFrameTime() * 10, 1)
		if abs(target - g.fb_view) < 0.01 do g.fb_view = target
	}
	fill(rect(FB_X, TOP_H, FB_W, 720 - TOP_H - STATUS_H), COL_PANEL)
	rl.DrawLine(FB_X, TOP_H, FB_X, 720 - STATUS_H, COL_EDGE)
	x0 := f32(FB_X + 8)
	y := f32(TOP_H + 6)

	label("CELLO FINGERBOARD", x0, y)
	text("nut at top, C string left", x0 + text_width("CELLO FINGERBOARD") + 10, y, COL_FAINT)
	y += 14

	// The key filter.
	bw := (f32(FB_W) - 16 - 8 * 4) / 9
	if button(rect(x0, y, bw, 18), "All", !g.fb_filter) do g.fb_filter = false
	for k, i in FB_KEYS_SHARP {
		r := rect(x0 + f32(i + 1) * (bw + 4), y, bw, 18)
		if button(r, key_short(int(k)), g.fb_filter && g.fb_key == k) {g.fb_filter = true; g.fb_key = k}
	}
	y += 22
	for k, i in FB_KEYS_FLAT {
		r := rect(x0 + f32(i + 1) * (bw + 4), y, bw, 18)
		if button(r, key_short(int(k)), g.fb_filter && g.fb_key == k) {g.fb_filter = true; g.fb_key = k}
	}
	if button(rect(x0, y, bw, 18), "Song", false) {g.fb_filter = true; g.fb_key = i8(g.song.key)}
	y += 24
	if g.fb_filter {
		k := int(g.fb_key)
		scale := ""
		tonic := ((7 * k) % 12 + 12) % 12
		for iv in ([7]int{0, 2, 4, 5, 7, 9, 11}) {
			scale = fmt.tprintf("%s %s", scale, note_letter(60 + tonic + iv, k))
		}
		minor := note_letter(60 + tonic + 9, k)
		text(fmt.tprintf("%s / %s minor:%s", music.key_name(k), minor, scale), x0, y, COL_TEXT)
	} else {
		text("All notes - pick a key to show only its notes", x0, y, COL_DIM)
	}
	y += 14

	// The hand position: two rows of five.
	hand := &HAND_POSITIONS[clamp(int(g.fb_hand), 0, len(HAND_POSITIONS) - 1)]
	pw := (f32(FB_W) - 16 - 4 * 4) / 5
	for hp, i in HAND_POSITIONS {
		if button(rect(x0 + f32(i % 5) * (pw + 4), y + f32(i / 5) * 22, pw, 18), hp.short, int(g.fb_hand) == i) do g.fb_hand = i8(i)
	}
	y += 46
	text(hand.name, x0, y, COL_ACCENT)
	// The legend, on the same line.
	{
		lx := x0 + 150
		rl.DrawCircleV({lx + 4, y + 5}, 4, COL_ACCENT)
		text("pointed", lx + 11, y, COL_DIM)
		lx += 58
		rl.DrawCircleV({lx + 4, y + 5}, 3, TRACK_COLOURS[0])
		rl.DrawCircleLines(i32(lx + 4), i32(y + 5), 5, rl.WHITE)
		text("playing", lx + 11, y, COL_DIM)
		lx += 58
		rl.DrawCircleLines(i32(lx + 4), i32(y + 5), 4, {90, 80, 76, 255})
		text("too high", lx + 11, y, COL_DIM)
	}
	y += 16

	// Tracking: the path from note to note (fingering.odin).
	if button(rect(x0, y, 64, 18), "Tracking", g.fb_track) do g.fb_track = !g.fb_track
	g.fb_track_n = int(stepper(rect(x0 + 70, y, 84, 18), f32(g.fb_track_n), 1, TRACK_MAX, 1, TRACK_DEFAULT_N, fmt.tprintf("%d notes", g.fb_track_n)))
	if button(rect(x0 + 160, y, 90, 18), TRACK_MODE_NAME[g.fb_track_mode], g.fb_track) {
		g.fb_track_mode = Track_Mode((int(g.fb_track_mode) + 1) % len(Track_Mode))
		set_status("tracking: %s", g.fb_track_mode == .Same_String ? "stay on the string while it can play the note" : "go to the physically nearest place for each note")
	}

	// The wheel over the board steps through them.
	if w := ui_take_wheel(rect(FB_X, FB_OPEN_Y - 12, FB_W, FB_END_Y - FB_OPEN_Y + 24)); w != 0 {
		g.fb_hand = i8(clamp(int(g.fb_hand) + (w < 0 ? 1 : -1), 0, len(HAND_POSITIONS) - 1))
	}

	// What is lit.
	target := fb_sheet_target()
	here := fb_hover()
	here_midi := here.ok ? fb_midi(here) : -1
	sounding: [16]int
	sounding_idx: [16]int // their index in the layer: their colour
	n_sounding := 0
	selected := -1
	if t := active_track(); t != nil {
		if g.player.playing {
			tick := player_tick(&g.player, &g.song)
			for note, i in t.notes {
				if note.tick > tick do break
				if tick < note.tick + note.len && n_sounding < len(sounding) {
					sounding[n_sounding] = music.pitch_midi(note.pitch)
					sounding_idx[n_sounding] = i
					n_sounding += 1
				}
			}
		}
		if g.selected >= 0 && g.selected < len(t.notes) do selected = music.pitch_midi(t.notes[g.selected].pitch)
	}
	is_sounding :: proc(list: []int, m: int) -> bool {
		for s in list do if s == m do return true
		return false
	}

	// The board: ebony, widening toward the bridge.
	cx := fb_center_x()
	{
		pad :: 12
		tl := rl.Vector2{cx - FB_HALF_NUT * 1.5 * 0.75 - pad, FB_NUT_Y}
		tr := rl.Vector2{cx + FB_HALF_NUT * 1.5 * 0.75 + pad, FB_NUT_Y}
		bl := rl.Vector2{cx - FB_HALF_END * 1.5 * 0.75 - pad, FB_END_Y + 8}
		br := rl.Vector2{cx + FB_HALF_END * 1.5 * 0.75 + pad, FB_END_Y + 8}
		board := rl.Color{34, 27, 25, 255}
		rl.DrawTriangle(tl, bl, br, board)
		rl.DrawTriangle(tl, br, tr, board)
		rl.DrawLineEx(tl, bl, 1, {70, 56, 50, 255})
		rl.DrawLineEx(tr, br, 1, {70, 56, 50, 255})
		// The nut.
		rl.DrawLineEx({tl.x - 2, FB_NUT_Y}, {tr.x + 2, FB_NUT_Y}, 4, {214, 206, 184, 255})
	}

	// Octave (half the string) and two octaves (three quarters): where a
	// cellist's hand finds its landmarks.
	for mark in ([2]int{12, 24}) {
		if !fb_in_view(mark) do continue
		my := fb_y(mark)
		l, r := fb_x(0, my) - 22, fb_x(3, my) + 22
		for xx := l; xx < r; xx += 6 do rl.DrawLineEx({xx, my}, {min(xx + 3, r), my}, 1, {110, 96, 80, 255})
		s := mark == 12 ? "8va" : "2x8va"
		text(s, l - text_width(s) - 3, my - 5, COL_FAINT)
	}

	// The hand: a line across the board where each finger stops the
	// strings, labelled at the right-hand edge of the screen.
	{
		// Labels are nudged apart where fingers sit close together (high up
		// the board), with a short tie back to their line.
		finger_line :: proc(semis: int, label_s: string, c: rl.Color, below: ^f32) {
			fy := fb_y(semis)
			l := fb_x(0, fy) - 16
			r := f32(1280 - 26)
			rl.DrawLineEx({l, fy}, {r - 6, fy}, 2, c)
			ly := max(fy, below^ + 15)
			rl.DrawLineEx({r - 6, fy}, {r, ly}, 2, c)
			fill(rect(r, ly - 7, 22, 14), c)
			text_centered(label_s, rect(r, ly - 7, 22, 14), COL_BG)
			below^ = ly
		}
		hand_col := [4]rl.Color{{96, 200, 255, 170}, {120, 230, 150, 170}, {250, 170, 90, 170}, {230, 120, 220, 170}}
		below := f32(-100)
		if hand.thumb > 0 do finger_line(int(hand.thumb), "T", {220, 220, 220, 170}, &below)
		for semi, f in hand.fingers {
			if semi <= 0 do continue
			finger_line(int(semi), fmt.tprintf("f%d", f + 1), hand_col[f], &below)
		}
	}

	// Strings: thickest on the left.
	for s in 0 ..< 4 {
		top := rl.Vector2{fb_x(s, FB_NUT_Y), FB_NUT_Y}
		bottom := rl.Vector2{fb_x(s, FB_END_Y + 8), FB_END_Y + 8}
		rl.DrawLineEx(top, bottom, 3 - f32(s) * 0.5, {176, 172, 160, 255})
		text_centered(FB_STRING_NAME[s], rect(top.x - 20, FB_OPEN_Y - 22, 40, 12), COL_DIM)
	}

	// The trail (tracking on): the last notes up to the playhead, or up to
	// the selected note when stopped.
	trail: [TRACK_MAX * 4]Tracked
	n_trail := fb_current_trail(trail[:])

	// The positions.
	for s in 0 ..< 4 {
		for n in 0 ..= FB_SEMIS {
			if !fb_in_view(n) do break
			m := FB_OPEN[s] + n
			py := fb_y(n)
			x := fb_x(s, py)
			r := fb_radius(n)
			lit_target := m == target
			lit_here := m == here_midi
			// With tracking on, the trail shows what is playing, at the one
			// place it is played; without, every place for it lights up.
			lit_play := !g.fb_track && is_sounding(sounding[:n_sounding], m)
			lit_sel := m == selected
			lit := lit_target || lit_here || lit_play || lit_sel
			if !lit && !fb_visible(m) do continue
			playable := fb_playable(m)

			if !playable {
				// Past the top of the cello's range.
				rl.DrawCircleLines(i32(x), i32(py), r, {90, 80, 76, 255})
			} else {
				natural := music.pitch_from_midi(m, fb_spell_key()).alter == 0
				rl.DrawCircleV({x, py}, r, natural ? rl.Color{96, 82, 74, 255} : rl.Color{64, 54, 50, 255})
				rl.DrawCircleLines(i32(x), i32(py), r, {150, 132, 112, 255})
			}
			if lit_play {
				col := COL_ACCENT
				for sm, k in sounding[:n_sounding] do if sm == m do col = track_colour(sounding_idx[k])
				rl.DrawCircleV({x, py}, r + 2, col)
				rl.DrawCircleLines(i32(x), i32(py), r + 3, rl.WHITE)
			}
			if lit_target || lit_here {
				rl.DrawCircleV({x, py}, r + 1, COL_ACCENT)
			}
			if lit_sel do rl.DrawCircleLines(i32(x), i32(py), r + 4, COL_ACCENT)
			if here.ok && here.string == s && here.semis == n do rl.DrawCircleLines(i32(x), i32(py), r + 2, rl.WHITE)

			// The name beside it, where there is room.
			if r >= 5 || lit {
				c := lit ? COL_TEXT : (playable ? COL_DIM : COL_FAINT)
				text(fb_name(m), x + r + 3, py - 5, c)
			}
		}
	}

	fb_track_draw(trail[:n_trail])

	// Click a circle: hear it.
	if here.ok && ui_take_click(rect(FB_X, FB_OPEN_Y - 12, FB_W, FB_END_Y - FB_OPEN_Y + 24)) {
		m := fb_midi(here)
		if !fb_playable(m) {
			set_error("%s is above the cello's range", fb_name(m))
		} else if t := active_track(); t != nil {
			player_preview(&g.player, t.inst, music.pitch_from_midi(m, fb_spell_key()))
		}
	}
}

// The status line while the mouse is on the board.
fingerboard_status :: proc() -> (string, bool) {
	here := fb_hover()
	if !here.ok do return "", false
	m := fb_midi(here)
	where_ := here.semis == 0 ? fmt.tprintf("open %s string", FB_STRING_NAME[here.string]) : fmt.tprintf("%s string, %d semitones up", FB_STRING_NAME[here.string], here.semis)
	return fmt.tprintf(
		"%s   %.1f Hz   %s   (all places: %s)%s",
		fb_name(m),
		music.midi_freq(f32(m)),
		where_,
		fb_places(m),
		fb_playable(m) ? "" : "   - above the cello's range",
	), true
}

// "G", "Bb", "F#" for a key signature.
@(private = "file")
key_short :: proc(key: int) -> string {
	n := music.key_name(key)
	for i in 0 ..< len(n) do if n[i] == ' ' do return n[:i]
	return n
}

// A note's letter (and accidental), no octave.
@(private = "file")
note_letter :: proc(midi, key: int) -> string {
	s := music.pitch_name_temp(music.pitch_from_midi(midi, key))
	i := len(s)
	for i > 0 && ((s[i - 1] >= '0' && s[i - 1] <= '9') || s[i - 1] == '-') do i -= 1
	return s[:i]
}
