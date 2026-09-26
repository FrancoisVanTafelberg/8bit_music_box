package app

/*
    The Helper's keyboard: for a layer whose instrument is played from keys
    (`keyboard 1` in its instrument file - the piano, harpsichord, celesta and
    organ).

    The keyboard is turned on its side and lined up with the sheet: each white
    key lies right beside its row - the sheet's rows ARE the white keys, one a
    letter - and each black key sits on the line between its two white keys,
    so a note on the sheet and its key are at the same height. Low notes at the
    bottom, as on the sheet; the back of the keyboard (where the black keys
    are) faces the sheet, the front edge is on the right.

    Lit like the fingerboard: the note under the mouse on the sheet (or that a
    click would place), the key under the mouse here (its row lights on the
    sheet too), the notes sounding while playing, the selected note. Click a
    key to hear it. The key filter dims the keys outside the chosen key.

    Tracking: the last N notes (chords count as one step) up to the playhead,
    or up to the selected note when stopped, each key filled in its step's
    colour with a line from the step before - the hand's path along the
    keyboard. In input mode, the note being played is a dot on its key, moved
    up or down by how sharp or flat it is.
*/

import "core:fmt"
import "core:math"
import "core:strings"
import "music"
import rl "vendor:raylib"

KB_X0 :: FB_X + 10 // the back of the keys
KB_LEN :: f32(170) // a white key's length
KB_BLACK :: KB_LEN * 0.6 // a black key's
KB_COL_X :: FB_X + 190 // the controls, right of the keys
KB_COL_W :: f32(1280 - 8 - KB_COL_X)

// The selected layer's keyboard, or nil.
kb_board :: proc() -> ^music.Board {
	t := active_track()
	if t == nil do return nil
	b := &inst_of(t).board
	return b.keyboard ? b : nil
}

kb_is_black :: proc(m: int) -> bool {
	switch (m % 12 + 12) % 12 {
	case 1, 3, 6, 8, 10:
		return true
	}
	return false
}

// Key m on the screen: a white key fills its row; a black key straddles the
// line between the row below it and the row above. Not ok if its row(s) are
// not on the sheet.
kb_key_rect :: proc(m: int) -> (r: rl.Rectangle, ok: bool) {
	if kb_is_black(m) {
		s := int(music.pitch_from_midi(m - 1, 0).step) // the white key below
		if s < sheet_lo() || s + 1 > sheet_hi() do return {}, false
		h := max(row_h() * 0.64, 6)
		return rect(KB_X0, row_y(s) - h / 2, KB_BLACK, h), true
	}
	s := int(music.pitch_from_midi(m, 0).step)
	if s < sheet_lo() || s > sheet_hi() do return {}, false
	return rect(KB_X0, row_y(s), KB_LEN, row_h()), true
}

// Where a note is marked on its key: on a black key its middle, on a white
// key the front part the black keys leave free.
kb_point :: proc(m: int) -> rl.Vector2 {
	r, _ := kb_key_rect(m)
	if kb_is_black(m) do return {r.x + r.width * 0.55, r.y + r.height / 2}
	return {KB_X0 + KB_BLACK + (KB_LEN - KB_BLACK) * 0.45, r.y + r.height / 2}
}

@(private = "file")
kb_range :: proc() -> (lo, hi: int) {
	ins := inst_of(active_track())
	return int(ins.lo), int(ins.hi)
}

// The key under the mouse, or -1. Black keys first: they lie on top.
kb_hover :: proc() -> int {
	if kb_board() == nil do return -1
	m := g.ui.mouse
	if m.x < KB_X0 || m.x >= KB_X0 + KB_LEN do return -1
	lo, hi := kb_range()
	for k in lo ..= hi {
		if !kb_is_black(k) do continue
		if r, ok := kb_key_rect(k); ok && rl.CheckCollisionPointRec(m, r) do return k
	}
	for k in lo ..= hi {
		if kb_is_black(k) do continue
		if r, ok := kb_key_rect(k); ok && rl.CheckCollisionPointRec(m, r) do return k
	}
	return -1
}

// The last `steps` steps of `t` up to the one starting at or before
// `upto_tick` (or, with `upto_note` >= 0, up to the step holding that note),
// oldest first. A step is a note, or notes starting together (a chord).
kb_track :: proc(t: ^music.Track, upto_tick: i32, upto_note: int, steps: int, out: []Tracked, ahead := 0) -> int {
	if steps <= 0 || len(out) == 0 do return 0
	ring: [TRAIL_CAP]Tracked
	count, step := 0, 0
	step_start: [TRACK_MAX + 1]int
	cur, extra := -1, 0
	i := 0
	for i < len(t.notes) {
		first := t.notes[i]
		beyond := upto_note < 0 ? first.tick > upto_tick : i > upto_note
		if beyond {
			if extra >= ahead do break
			extra += 1
		}
		j := i + 1
		for j < len(t.notes) && j - i < 10 {
			nj := t.notes[j]
			if nj.tick - first.tick > STRUM_TICKS || nj.tick >= first.tick + first.len do break
			j += 1
		}
		step_start[step % (TRACK_MAX + 1)] = count
		for k in i ..< j {
			ring[count % len(ring)] = {{}, music.pitch_midi(t.notes[k].pitch), k, step, 0}
			count += 1
		}
		if !beyond do cur = step
		step += 1
		i = j
	}
	return trail_finish(ring[:], count, step, cur, step_start[:], steps, ahead, out)
}

keyboard_draw :: proc() {
	t := active_track()
	ins := inst_of(t)
	lo, hi := kb_range()
	label(fmt.tprintf("%s KEYBOARD", strings.to_upper(ins.name, context.temp_allocator)), FB_X + 8, TOP_H + 5)

	// What is lit.
	target := fb_sheet_target()
	here := kb_hover()
	selected := -1
	if g.selected >= 0 && g.selected < len(t.notes) do selected = music.pitch_midi(t.notes[g.selected].pitch)
	sounding: [32]int
	n_sounding := 0
	if g.player.playing && !g.fb_track {
		tick := player_tick(&g.player, &g.song)
		for note in t.notes {
			if note.tick > tick do break
			if tick < note.tick + note.len && n_sounding < len(sounding) {
				sounding[n_sounding] = music.pitch_midi(note.pitch)
				n_sounding += 1
			}
		}
	}
	trail: [TRAIL_CAP]Tracked
	n_trail := fb_current_trail(trail[:])
	first_step := n_trail > 0 ? trail[0].step : 0
	steps := n_trail > 0 ? trail[n_trail - 1].step - first_step + 1 : 1
	key_fill :: proc(m, target, here, selected: int, sounding: []int, trail: []Tracked, first_step, steps: int, base: rl.Color) -> rl.Color {
		c := base
		// Outside the filter's key: white keys go grey, black keys go white -
		// a dark grey black key would look much like any other.
		if !fb_in_key(m) do c = kb_is_black(m) ? rl.Color{214, 210, 198, 255} : rl.Color{120, 118, 112, 255}
		for s in sounding do if s == m do c = COL_ACCENT
		for tr in trail do if tr.midi == m do c = colour_mix(c, track_colour(tr.step), trail_alpha(tr.rel))
		if m == target || m == here do c = COL_ACCENT
		return c
	}

	// White keys, then the black keys over them.
	WHITE :: rl.Color{226, 222, 210, 255}
	BLACK :: rl.Color{28, 26, 32, 255}
	for m in lo ..= hi {
		if kb_is_black(m) do continue
		r, ok := kb_key_rect(m)
		if !ok do continue
		fill(r, key_fill(m, target, here, selected, sounding[:n_sounding], trail[:n_trail], first_step, steps, WHITE))
		rl.DrawLineEx({r.x, r.y}, {r.x + r.width, r.y}, 1, {90, 88, 84, 255})
		if m == selected do outline(rect(r.x + 1, r.y + 1, r.width - 2, r.height - 2), COL_ACCENT)
		// Each C by name at the front edge; middle C in the accent colour.
		if m % 12 == 0 && row_h() >= 10 {
			name := midi_name(m)
			text(name, r.x + r.width - text_width(name) - 4, r.y + (r.height - 10) / 2, m == 60 ? rl.Color{200, 140, 0, 255} : {70, 68, 64, 255})
		}
	}
	for m in lo ..= hi {
		if !kb_is_black(m) do continue
		r, ok := kb_key_rect(m)
		if !ok do continue
		fill(r, key_fill(m, target, here, selected, sounding[:n_sounding], trail[:n_trail], first_step, steps, BLACK))
		outline(r, {10, 10, 12, 255})
		if m == selected do outline(rect(r.x - 1, r.y - 1, r.width + 2, r.height + 2), COL_ACCENT)
	}
	// The keyboard's ends, and its back (toward the sheet).
	{
		top_r, _ := kb_key_rect(hi)
		bot_r, _ := kb_key_rect(lo)
		y0 := max(top_r.y, f32(ROWS_Y))
		y1 := min(bot_r.y + bot_r.height, f32(ROWS_Y) + rows_h())
		rl.DrawLineEx({KB_X0 - 2, y0}, {KB_X0 - 2, y1}, 3, {90, 60, 40, 255})
		outline(rect(KB_X0, y0, KB_LEN, y1 - y0), {90, 88, 84, 255})
	}

	// The trail: a line from each step's notes to the next's, then the notes.
	for b in trail[:n_trail] {
		if b.step == first_step do continue
		from := -1
		best := 1 << 20
		for a, k in trail[:n_trail] {
			if a.step != b.step - 1 do continue
			if d := abs(a.midi - b.midi); d < best {best = d; from = k}
		}
		if from < 0 || trail[from].midi == b.midi do continue
		a := trail[from]
		// As on the fingerboard: Tracking points back at -1, Suggest on at
		// +1; only that line full, with its arrow; every line numbered.
		tail, head := a, b
		about := b.rel
		if !g.fb_suggest {
			tail, head = b, a
			about = a.rel
		}
		key := abs(about) == 1
		al := trail_alpha(about)
		pt, ph := kb_point(tail.midi), kb_point(head.midi)
		gradient_line(pt, ph, faded(track_colour(tail.step), al), faded(track_colour(head.step), al), key ? 3 : 2)
		if key do arrow_head(pt, ph, 6, faded(track_colour(head.step), al))
		trail_label(pt, ph, about, al)
	}
	for it in trail[:n_trail] {
		p := kb_point(it.midi)
		rl.DrawCircleV(p, 5, faded(track_colour(it.step), trail_alpha(it.rel)))
		if it.rel == 0 do rl.DrawCircleLines(i32(p.x), i32(p.y), 7, rl.WHITE)
	}

	// Input mode: the note being played, on its key, off-centre by its cents.
	if g.input.on {
		for f in g.input.notes[:g.input.n] {
			m := note_of(f)
			if _, ok := kb_key_rect(m); !ok do continue
			cents := f - f32(m)
			p := kb_point(m)
			p.y -= cents * row_h() * 0.5
			col := input_colour()
			rl.DrawCircleV(p, 9, {0, 0, 0, 160})
			rl.DrawCircleV(p, 7.5, col)
			rl.DrawCircleLines(i32(p.x), i32(p.y), 9, rl.WHITE)
		}
	}

	// Click a key: hear it.
	if here >= 0 && ui_take_click(rect(KB_X0, ROWS_Y, KB_LEN, rows_h())) {
		player_preview(&g.player, t.inst, music.pitch_from_midi(here, fb_spell_key()))
	}

	keyboard_controls(t, lo, hi, here)
}

// The column right of the keys: the key filter, tracking, what is pointed at.
@(private = "file")
keyboard_controls :: proc(t: ^music.Track, lo, hi, here: int) {
	x := f32(KB_COL_X)
	y := f32(ROWS_Y)
	w := KB_COL_W
	text(fmt.tprintf("%s - %s", midi_name(lo), midi_name(hi)), x, y, COL_DIM)
	y += 16

	label("KEY", x, y)
	y += 13
	bw := (w - 3 * 3) / 4
	keys := [?]i8{0, 1, 2, 3, 4, 5, 6, 7, -1, -2, -3, -4, -5, -6, -7}
	if button(rect(x, y, bw, 16), "All", !g.fb_filter) do g.fb_filter = false
	if button(rect(x + bw + 3, y, bw, 16), "Song", false) {g.fb_filter = true; g.fb_key = i8(g.song.key)}
	for k, i in keys {
		slot := i + 2
		r := rect(x + f32(slot % 4) * (bw + 3), y + f32(slot / 4) * 19, bw, 16)
		if button(r, key_short(int(k)), g.fb_filter && g.fb_key == k) {g.fb_filter = true; g.fb_key = k}
	}
	y += 19 * 5 + 4
	if g.fb_filter {
		k := int(g.fb_key)
		tonic := ((7 * k) % 12 + 12) % 12
		text(fmt.tprintf("%s / %s minor", music.key_name(k), note_letter(60 + tonic + 9, k)), x, y, COL_TEXT)
		y += 13
		scale := ""
		for iv in ([7]int{0, 2, 4, 5, 7, 9, 11}) do scale = fmt.tprintf("%s %s", scale, note_letter(60 + tonic + iv, k))
		text(scale, x, y, COL_DIM)
	} else {
		text("All keys lit", x, y, COL_DIM)
	}
	y += 22

	label("TRACKING", x, y)
	y += 13
	if button(rect(x, y, 64, 18), track_show_name(), g.fb_track) do track_show_step()
	g.fb_track_n = int(stepper(rect(x + 68, y, w - 68, 18), f32(g.fb_track_n), 1, TRACK_MAX - 1, 1, TRACK_DEFAULT_N, fmt.tprintf(g.fb_suggest ? "next %d" : "%d notes", g.fb_track_n)))
	y += 22
	// What the mic listens for: one note, or chords.
	if button(rect(x, y, 64, 18), g.input.chords ? "Chords" : "Single", g.input.chords) do input_chords_toggle()
	text(g.input.chords ? "mic: chords" : "mic: one note", x + 68, y + 4, COL_DIM)
	y += 24
	text(g.fb_suggest ? "the next notes to play, from" : "the last notes up to the", x, y, COL_FAINT)
	y += 11
	text(g.fb_suggest ? "the playhead (the selected" : "playhead (or the selected", x, y, COL_FAINT)
	y += 11
	text(g.fb_suggest ? "note, or the cursor): +1 next" : "note): -1 the one before", x, y, COL_FAINT)
	y += 22

	// What is pointed at.
	m := here
	if m < 0 do m = fb_sheet_target()
	if m >= 0 {
		label("NOTE", x, y)
		y += 13
		text(fb_name(m), x, y, COL_ACCENT, FONT_BIG)
		y += 24
		text(fmt.tprintf("%.1f Hz", music.midi_freq(f32(m))), x, y, COL_TEXT)
		y += 13
		oct := m / 12 - 1
		text(fmt.tprintf("%s key, octave %d", kb_is_black(m) ? "black" : "white", oct), x, y, COL_DIM)
		y += 13
		if i32(m) < inst_of(t).lo || i32(m) > inst_of(t).hi do text("outside the range", x, y, COL_BAD)
		y += 20
	}
	if g.input.on {
		label("MIC", x, y)
		y += 13
		if g.input.n == 0 do text("-", x, y, COL_DIM, FONT_BIG)
		for i := g.input.n - 1; i >= 0; i -= 1 { // highest first
			f := g.input.notes[i]
			mm := note_of(f)
			c := int(math.round((f - f32(mm)) * 100))
			text(fmt.tprintf("%s %s%d", fb_name(mm), c >= 0 ? "+" : "", c), x, y, abs(c) <= 10 ? COL_GOOD : (abs(c) <= music.CHECK_TUNE ? COL_ACCENT : COL_BAD), FONT_BIG)
			y += 22
		}
	}

	if wh := ui_take_wheel(rect(KB_X0, ROWS_Y, KB_LEN, rows_h())); wh != 0 do g.fb_track_n = clamp(g.fb_track_n + (wh > 0 ? 1 : -1), 1, TRACK_MAX)
}

// The status line while the mouse is on the keys.
keyboard_status :: proc() -> (string, bool) {
	m := kb_hover()
	if m < 0 do return "", false
	return fmt.tprintf("%s   %.1f Hz   %s key   click to hear", fb_name(m), music.midi_freq(f32(m)), kb_is_black(m) ? "black" : "white"), true
}
