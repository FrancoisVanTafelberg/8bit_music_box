package app

/*
    The sheet: four bars across, the whole piano range top to bottom.

    VERTICAL. One row per line-or-space (a staff step), A0 at the bottom to C8
    at the top, 12 pixels each. Every even step is a line, which makes one
    continuous staff holding both clefs; the treble and bass five-line groups
    are drawn bold, middle C's ledger line dashed, everything else faint. See
    DESIGN.md 3.1.

    HORIZONTAL. Ticks (24 to a quarter). A note snaps to slots of its own
    length counted from the start of its bar - DESIGN.md 3.2.

    Every layer is drawn; the active one last and at full strength, with its
    instrument's out-of-range rows shaded. Only the active layer is edited.
*/

import "core:fmt"
import "music"
import rl "vendor:raylib"

TOP_H :: 32
STATUS_H :: 20
// The Cello Helper's panel is half as wide (panel.odin lays it out compact).
PANEL_W :: 104 when CELLO else 208
// Clef marks, the frequency ratios of the key lines (key_ratio), note names.
GUTTER_W :: 72
GUTTER_NAME_X :: GUTTER_W - 24 // where the note names start
BARS_X :: PANEL_W + GUTTER_W
// In the Cello Helper the fingerboard takes the right of the screen.
BARS_W :: FB_X_CELLO - 8 - BARS_X when CELLO else 1280 - BARS_X - 8
SHEET_R :: BARS_X + BARS_W + 8 // the sheet's right edge
BAR_NUM_Y :: TOP_H + 2
ROWS_Y :: TOP_H + 18
// The rows the sheet shows (sheet_range_update, every frame): the whole
// piano, or - with the range button on - only the active layer's instrument's
// compass, each row taller for it. The music box starts on the piano, the
// Cello Helper on the instrument.
PIANO_ROWS_H :: music.STEP_COUNT * 12 // the space the rows have
ROW_H_MAX :: 36
STRIP_Y :: ROWS_Y + PIANO_ROWS_H + 4

sheet_lo :: #force_inline proc() -> int {return g.sheet_lo}
sheet_hi :: #force_inline proc() -> int {return g.sheet_hi}
row_h :: #force_inline proc() -> f32 {return f32(g.row_h)}
rows_h :: #force_inline proc() -> f32 {return f32((g.sheet_hi - g.sheet_lo + 1) * g.row_h)}
// A note's head and body, half-heights: bigger on taller rows.
note_half :: proc() -> f32 {return g.row_h >= 18 ? 7 : 5}
body_half :: proc() -> f32 {return g.row_h >= 18 ? 4 : 3}

sheet_range_update :: proc() {
	lo, hi := music.STEP_LO, music.STEP_HI
	if g.fit_range {
		if t := active_track(); t != nil {
			ins := inst_of(t)
			// The lowest note spelled as low a letter as it goes, the highest
			// as high: C#2 is on the C row, Db6 on the D row.
			lo = max(int(music.pitch_from_midi(int(ins.lo), 7).step), music.STEP_LO)
			hi = min(int(music.pitch_from_midi(int(ins.hi), -7).step), music.STEP_HI)
		}
	}
	if hi < lo do lo, hi = music.STEP_LO, music.STEP_HI
	g.sheet_lo, g.sheet_hi = lo, hi
	g.row_h = clamp(PIANO_ROWS_H / (hi - lo + 1), 12, ROW_H_MAX)
}

STRIP_H :: 18

Acc_Mode :: enum {
	Key, // whatever the key signature says
	Sharp,
	Flat,
	Natural,
}

Drag :: struct {
	active: bool,
	note:   music.Note, // the note as it was when grabbed
	grab:   i32, // ticks between the note's start and where it was grabbed
	moved:  bool,
}

// What is under the mouse on the sheet.
Hover :: struct {
	ok:       bool,
	step:     int,
	raw_tick: i32, // unsnapped
	tick:     i32, // snapped to the current length's slot
}

row_y :: proc(step: int) -> f32 {
	return f32(ROWS_Y) + f32(sheet_hi() - step) * row_h()
}

row_center :: proc(step: int) -> f32 {
	return row_y(step) + row_h() / 2
}

page_ticks :: proc() -> i32 {
	return music.bar_ticks(&g.song) * BARS_PER_PAGE
}

page_start :: proc() -> i32 {
	return g.page * page_ticks()
}

page_count :: proc() -> i32 {
	return max((g.song.bars + BARS_PER_PAGE - 1) / BARS_PER_PAGE, 1)
}

px_per_tick :: proc() -> f32 {
	return f32(BARS_W) / f32(page_ticks())
}

tick_x :: proc(tick: i32) -> f32 {
	return f32(BARS_X) + f32(tick - page_start()) * px_per_tick()
}

// The layer being edited; nil if there is none (the metronome, layer 0,
// never is).
active_track :: proc() -> ^music.Track {
	if g.active < 0 || g.active >= len(g.song.tracks) do return nil
	if g.song.tracks[g.active].metronome do return nil
	return &g.song.tracks[g.active]
}

current_snap :: proc() -> i32 {
	if rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT) do return 3
	return music.snap_ticks(g.length, g.mod)
}

// Snap a tick to the slot grid, counting from the start of its bar.
snap_tick :: proc(tick: i32) -> i32 {
	bt := music.bar_ticks(&g.song)
	bar := tick / bt
	in_bar := tick - bar * bt
	sn := current_snap()
	return bar * bt + in_bar / sn * sn
}

sheet_hover :: proc() -> Hover {
	m := g.ui.mouse
	if m.x < BARS_X || m.x >= BARS_X + BARS_W || m.y < ROWS_Y || m.y >= ROWS_Y + rows_h() do return {}
	h: Hover
	h.ok = true
	h.step = sheet_hi() - int((m.y - ROWS_Y) / row_h())
	h.raw_tick = page_start() + i32((m.x - BARS_X) / px_per_tick())
	h.tick = snap_tick(h.raw_tick)
	return h
}

// The pitch a click on this step makes, given the key and the accidental mode.
placed_pitch :: proc(step: int) -> music.Pitch {
	alter := music.key_alter(int(g.song.key), step)
	switch g.acc_mode {
	case .Key:
	case .Sharp:
		alter = 1
	case .Flat:
		alter = -1
	case .Natural:
		alter = 0
	}
	if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) do alter = 1
	if rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) do alter = -1
	return {i8(step), alter}
}

// The instrument a track plays: built in, from a file, or from the song.
inst_of :: proc(t: ^music.Track) -> ^music.Instrument {
	return music.inst_get(&g.song, t.inst)
}

// A layer's colour: its own if it has been given one (Set colour), else its
// instrument's.
track_color :: proc(t: ^music.Track) -> rl.Color {
	if t.color[3] != 0 do return inst_color(t.color)
	return inst_color(inst_of(t).color)
}

in_range :: proc(inst: music.Inst_Id, p: music.Pitch) -> bool {
	ins := music.inst_get(&g.song, inst)
	m := i32(music.pitch_midi(p))
	return m >= ins.lo && m <= ins.hi
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

sheet_draw :: proc() {
	fill(rect(PANEL_W, TOP_H, SHEET_R - PANEL_W, 720 - TOP_H - STATUS_H), COL_SHEET)
	t := active_track()
	bt := music.bar_ticks(&g.song)
	ps := page_start()
	right := f32(BARS_X + BARS_W)

	// Rows the active instrument cannot play: shaded, so the playable band
	// stands out as the lit part of the page.
	if t != nil {
		for step in sheet_lo() ..= sheet_hi() {
			p := music.Pitch{i8(step), music.key_alter(int(g.song.key), step)}
			if !in_range(t.inst, p) {
				fill(rect(BARS_X, row_y(step), BARS_W, row_h()), {8, 9, 16, 255})
			}
		}
	}

	if g.key_lines do key_lines_draw()

	// The hovered row, faintly, all the way across.
	hov := sheet_hover()
	if hov.ok do fill(rect(PANEL_W, row_y(hov.step), SHEET_R - PANEL_W, row_h()), {255, 255, 255, 10})
	// ...and in the Cello Helper, the row of the fingerboard note under the
	// mouse, so a position on the board can be found on the staff.
	when CELLO {
		if fh := fb_hover(); fh.ok && overlay_none() {
			step := int(music.pitch_from_midi(fb_midi(fh), fb_spell_key()).step)
			if step >= sheet_lo() && step <= sheet_hi() {
				fill(rect(PANEL_W, row_y(step), SHEET_R - PANEL_W, row_h()), with_alpha(COL_ACCENT, 40))
			}
		}
	}

	// Staff lines.
	for step in sheet_lo() ..= sheet_hi() {
		if !music.step_is_line(step) do continue
		y := row_center(step)
		switch {
		case music.step_is_grand_staff(step):
			rl.DrawLineEx({BARS_X, y}, {right, y}, 1, {150, 156, 196, 255})
		case step == 28:
			// Middle C: dashed, the ledger line between the staves.
			for x := f32(BARS_X); x < right; x += 8 do rl.DrawLineEx({x, y}, {min(x + 4, right), y}, 1, {120, 124, 170, 255})
		case:
			rl.DrawLineEx({BARS_X, y}, {right, y}, 1, {40, 44, 70, 255})
		}
	}

	// Bar, beat and slot lines.
	top, bottom := f32(ROWS_Y), f32(ROWS_Y + rows_h())
	sn := current_snap()
	beat := music.beat_ticks(&g.song)
	for b in 0 ..< BARS_PER_PAGE {
		bar := g.page * BARS_PER_PAGE + i32(b)
		start := bar * bt
		for k := i32(0); k < bt; k += 1 {
			x := tick_x(start + k)
			switch {
			case k == 0:
				rl.DrawLineEx({x, top}, {x, bottom}, 2, {170, 170, 214, 255})
			case k % beat == 0:
				rl.DrawLineEx({x, top}, {x, bottom}, 1, {70, 74, 110, 255})
			case k % sn == 0 && f32(sn) * px_per_tick() >= 5:
				rl.DrawLineEx({x, top}, {x, bottom}, 1, {30, 33, 54, 255})
			}
		}
		// Bar number, and past the song's end a note that it is empty room.
		bx := tick_x(start)
		text(fmt.tprintf("%d", bar + 1), bx + 8, BAR_NUM_Y, bar < g.song.bars ? COL_DIM : COL_FAINT)
	}
	rl.DrawLineEx({right, top}, {right, bottom}, 2, {170, 170, 214, 255})

	gutter_draw(hov)

	// Notes: the other layers first and dim, the active one last and bright.
	playing_tick := g.player.playing ? player_tick(&g.player, &g.song) : -1
	// Cello Helper, tracking on: the active layer's notes in the trail take
	// the fingerboard's colours, fading back to the layer's as it moves on.
	trail: [TRACK_MAX * 4]Tracked
	n_trail := 0
	when CELLO do n_trail = fb_current_trail(trail[:])
	for &tr, i in g.song.tracks do if i != g.active && !tr.metronome do notes_draw(&tr, false, playing_tick)
	metronome_draw(playing_tick)
	if t != nil do notes_draw(t, true, playing_tick, trail[:n_trail])

	// The ghost of the note a click would place.
	if hov.ok && t != nil && !g.drag.active && overlay_none() {
		if music.track_note_at(t, hov.step, hov.raw_tick) < 0 {
			p := placed_pitch(hov.step)
			col := track_color(t)
			if !in_range(t.inst, p) do col = COL_BAD
			x0 := tick_x(hov.tick)
			w := f32(music.note_ticks(g.length, g.mod)) * px_per_tick()
			fill(rect(x0, row_center(hov.step) - note_half(), max(w - 1, 3), 2 * note_half()), with_alpha(col, 70))
			outline(rect(x0, row_center(hov.step) - note_half(), max(w - 1, 3), 2 * note_half()), with_alpha(col, 160))
		}
	}

	// The bar cursor, where Play will start (left/right arrows).
	if !g.player.playing {
		c := play_from()
		if c >= ps && c < ps + page_ticks() {
			x := tick_x(c)
			rl.DrawLineEx({x, top}, {x, bottom}, 2, with_alpha(COL_ACCENT, 110))
			rl.DrawTriangle({x - 6, top - 8}, {x, top}, {x + 6, top - 8}, COL_ACCENT)
		}
	}

	// The playhead.
	if g.player.playing && playing_tick >= ps && playing_tick < ps + page_ticks() {
		x := tick_x(playing_tick)
		rl.DrawLineEx({x, top - 4}, {x, bottom}, 2, COL_ACCENT)
	}
	// Bar or Page scope: where Play will stop.
	if g.player.playing && g.player.stop_tick > ps && g.player.stop_tick <= ps + page_ticks() {
		x := tick_x(g.player.stop_tick)
		rl.DrawLineEx({x, top - 4}, {x, bottom}, 2, with_alpha(COL_BAD, 160))
	}

	// What the microphone hears (input.odin): the take, and the live dot.
	input_sheet_draw()

	// Instrument rows only: say how many notes of this layer are out of
	// sight above or below (switch to the piano range to edit them).
	if g.fit_range && t != nil {
		above, below := 0, 0
		for n in t.notes {
			st := int(n.pitch.step)
			if st > sheet_hi() do above += 1
			if st < sheet_lo() do below += 1
		}
		if above > 0 do text(fmt.tprintf("^ %d note%s above - piano range to edit", above, above == 1 ? "" : "s"), BARS_X + 4, ROWS_Y + 2, COL_BAD)
		if below > 0 do text(fmt.tprintf("v %d note%s below - piano range to edit", below, below == 1 ? "" : "s"), BARS_X + 4, ROWS_Y + rows_h() - 12, COL_BAD)
	}

	strip_draw()
	when CELLO do fingerboard_draw()
}

@(private = "file")
notes_draw :: proc(t: ^music.Track, active: bool, playing_tick: i32, trail: []Tracked = nil) {
	base := track_color(t)
	ps := page_start()
	pe := ps + page_ticks()
	left, right := f32(BARS_X), f32(BARS_X + BARS_W)
	muted := !music.track_audible(&g.song, t)

	for n, i in t.notes {
		if n.tick >= pe do break
		if n.tick + n.len <= ps do continue
		step := int(n.pitch.step)
		if step < sheet_lo() || step > sheet_hi() do continue
		x0 := max(tick_x(n.tick), left)
		x1 := min(tick_x(n.tick + n.len), right)
		yc := row_center(step)
		sounding := playing_tick >= n.tick && playing_tick < n.tick + n.len && !muted

		col := base
		if !active do col = with_alpha(base, muted ? 40 : 95)
		if active && muted do col = with_alpha(base, 150)
		in_trail := false
		for tr in trail {
			if tr.index != i do continue
			first := trail[0].step
			col = colour_mix(base, track_colour(tr.step), trail_weight(tr.step - first, trail[len(trail) - 1].step - first + 1))
			in_trail = true
			break
		}
		if sounding && !in_trail do col = lighten(base, 0.55)
		// Outside the instrument's range (from a file, or another instrument's
		// part): red, so it can be found and moved or deleted.
		if active && !in_range(t.inst, n.pitch) do col = COL_BAD

		// The body: how long it lasts. The head: where it starts, a square
		// pixel block, because this is an 8-bit music box.
		fill(rect(x0 + 1, yc - body_half(), max(x1 - x0 - 2, 1), 2 * body_half()), col)
		if tick_x(n.tick) >= left {
			head := rect(x0, yc - note_half(), min(2 * note_half(), max(x1 - x0, 4)), 2 * note_half())
			fill(head, active || sounding ? lighten(col, 0.2) : col)
			if active do outline(head, {0, 0, 0, 120})
		}
		if sounding do outline(rect(x0 - 1, yc - note_half() - 1, x1 - x0 + 2, 2 * note_half() + 2), rl.WHITE)
		if active && i == g.selected do outline(rect(x0 - 2, yc - note_half() - 2, x1 - x0 + 4, 2 * note_half() + 4), COL_ACCENT)

		// Accidentals, only where the key signature does not already say so.
		if active && tick_x(n.tick) - 8 >= left {
			if n.pitch.alter != music.key_alter(int(g.song.key), step) {
				acc := "n"
				switch n.pitch.alter {
				case 1:
					acc = "#"
				case -1:
					acc = "b"
				case 2:
					acc = "x"
				case -2:
					acc = "bb"
				}
				text(acc, x0 - 7 - f32(len(acc) - 1) * 5, yc - 5, COL_TEXT)
			}
		}
	}
}

// Note names down the left of the sheet (every row, with its octave), and
// the clef marks.
@(private = "file")
gutter_draw :: proc(hov: Hover) {
	x := f32(PANEL_W)
	fill(rect(x, ROWS_Y, GUTTER_W, rows_h()), COL_PANEL)
	for step in sheet_lo() ..= sheet_hi() {
		y := row_y(step)
		letter := step % 7
		name := music.pitch_name_temp({i8(step), 0})
		is_c := letter == 0
		c := is_c ? COL_TEXT : COL_DIM
		// With key lines on, the rows the key signature changes are named
		// as they sound (F#, Bb), and the home chord's rows are coloured.
		alter := music.key_alter(int(g.song.key), step)
		if g.key_lines {
			if alter != 0 {
				name = music.pitch_name_temp({i8(step), alter})
				c = alter > 0 ? KEY_SHARP_TEXT : KEY_FLAT_TEXT
			}
			switch (letter - key_tonic_letter() + 7) % 7 {
			case 0:
				c = COL_ACCENT
			case 2, 4:
				c = lighten(with_alpha(COL_ACCENT, 255), 0.4)
			}
		}
		if hov.ok && hov.step == step do c = COL_ACCENT
		// Every row by its full name, letter and octave: D3, F#3, C4.
		text(name, x + GUTTER_NAME_X, y + (row_h() - 10) / 2, c)
		if is_c do rl.DrawLineEx({x + GUTTER_NAME_X - 2, y + row_h()}, {x + GUTTER_W, y + row_h()}, 1, COL_EDGE)

		// The row's frequency ratio to the reference note (key lines on).
		if g.key_lines {
			if rt, octave, ok := key_ratio(step); ok {
				rc := COL_FAINT
				if octave do rc = COL_DIM
				if step == ratio_ref_step() do rc = COL_ACCENT
				text(rt, x + GUTTER_NAME_X - 3 - text_width(rt), y + (row_h() - 10) / 2, rc)
			}
		}
	}
	// Clef marks where each clef's own line is: G on G4, C on C4, F on F3.
	clef :: proc(step: int, s: string) {
		if step < sheet_lo() || step > sheet_hi() do return // not on the rows shown
		y := row_center(step)
		fill(rect(PANEL_W + 3, y - 6, 12, 12), COL_ACCENT)
		text(s, PANEL_W + 6, y - 4, COL_BG)
	}
	clef(32, "G")
	clef(28, "C")
	clef(24, "F")
}

// Every page as a box: where you are, where the playhead is, click to go.
@(private = "file")
strip_draw :: proc() {
	n := page_count()
	text(fmt.tprintf("%d/%d", g.page + 1, n), PANEL_W + 4, STRIP_Y + 4, COL_DIM)
	// The practice controls (input.odin) have the right-hand end.
	w := min(f32(BARS_W - 30 - PRACTICE_W - 8) / f32(n), 48)
	play_page := g.player.playing ? player_tick(&g.player, &g.song) / page_ticks() : -1
	for i in 0 ..< n {
		r := rect(BARS_X + f32(i) * w, STRIP_Y, w - 2, STRIP_H)
		c := COL_BUTTON
		if i == g.page do c = COL_BUTTON_ON
		fill(r, hovered(r) ? COL_BUTTON_HOT : c)
		if i == play_page do fill(rect(r.x, r.y + r.height - 3, r.width, 3), COL_ACCENT)
		// A tick of the active layer's colour if it has notes on that page.
		if t := active_track(); t != nil {
			s, e := i * page_ticks(), (i + 1) * page_ticks()
			for note in t.notes {
				if note.tick >= e do break
				if note.tick >= s {
					fill(rect(r.x + 2, r.y + 2, 4, 4), track_color(t))
					break
				}
			}
		}
		if w >= 16 do text_centered(fmt.tprintf("%d", i + 1), r, i == g.page ? COL_ACCENT : COL_DIM)
		if ui_take_click(r) do g.page = i
	}
	add := rect(BARS_X + f32(n) * w, STRIP_Y, 26, STRIP_H)
	if button(add, "+") {
		g.song.bars = (page_count() + 1) * BARS_PER_PAGE
		g.page = page_count() - 1
		g.dirty = true
	}
	practice_draw()
}

// The metronome's clicks (metronome.odin): not on the staff - they have no
// pitch worth reading - but as ticks along the top of the rows, beside the
// bar numbers: tall on the first beat of a bar, short on the rest, lit as
// they play.
@(private = "file")
metronome_draw :: proc(playing_tick: i32) {
	if len(g.song.tracks) == 0 || !g.song.tracks[0].metronome do return
	t := &g.song.tracks[0]
	ps := page_start()
	pe := ps + page_ticks()
	muted := !music.track_audible(&g.song, t)
	for n in t.notes {
		if n.tick >= pe do break
		if n.tick < ps do continue
		x := tick_x(n.tick)
		down := n.vel >= 110
		h := f32(down ? 7 : 4)
		c := down ? rl.Color{200, 200, 220, 255} : rl.Color{130, 134, 170, 255}
		if muted do c = COL_FAINT
		if playing_tick >= n.tick && playing_tick < n.tick + music.beat_ticks(&g.song) && !muted do c = COL_ACCENT
		fill(rect(x + 1, f32(ROWS_Y) - h - 1, down ? 4 : 3, h), c)
	}
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

sheet_input :: proc() {
	t := active_track()
	if t == nil do return
	hov := sheet_hover()

	// Dragging a note carries on wherever the mouse goes, released or not.
	if g.drag.active {
		if !g.ui.down {
			drag_finish(t)
		} else if hov.ok {
			drag_move(t, hov)
		}
		return
	}

	// The piano gutter: click to hear a row; right-click makes it the
	// reference note the ratios count from (again: back to automatic).
	gut := rect(PANEL_W, ROWS_Y, GUTTER_W, rows_h())
	if ui_take_click(gut) {
		step := sheet_hi() - int((g.ui.mouse.y - ROWS_Y) / row_h())
		player_preview(&g.player, t.inst, placed_pitch(step))
	}
	if ui_take_right(gut) {
		step := sheet_hi() - int((g.ui.mouse.y - ROWS_Y) / row_h())
		if int(g.ratio_ref) == step {
			g.ratio_ref = -1
			set_status("ratios count from the key's tonic again (%s)", music.pitch_name_temp(key_pitch(ratio_ref_step())))
		} else {
			g.ratio_ref = i16(step)
			set_status("ratios now count from %s = 1:1  (right-click it again for automatic)", music.pitch_name_temp(key_pitch(step)))
		}
	}

	if !hov.ok do return
	area := rect(BARS_X, ROWS_Y, BARS_W, rows_h())
	under := music.track_note_at(t, hov.step, hov.raw_tick)

	if ui_take_click(area) {
		ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
		shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		if under >= 0 && (ctrl || shift) {
			// Ctrl+click: a copy an octave lower; Shift+click: an octave
			// higher. Same place, same length, same layer.
			octave_copy(t, under, ctrl ? -1 : 1)
		} else if under >= 0 {
			// Grab it: select, hear it, and be ready to drag.
			g.selected = under
			n := t.notes[under]
			undo_push()
			g.drag = {active = true, note = n, grab = hov.raw_tick - n.tick}
			player_preview(&g.player, t.inst, n.pitch)
		} else {
			p := placed_pitch(hov.step)
			if !in_range(t.inst, p) {
				ins := inst_of(t)
				set_error(
					"%s is outside the %s's range (%s - %s)",
					music.pitch_name_temp(p),
					ins.name,
					midi_name(int(ins.lo)),
					midi_name(int(ins.hi)),
				)
				return
			}
			undo_push()
			n := music.Note{tick = hov.tick, len = music.note_ticks(g.length, g.mod), pitch = p, vel = music.DEFAULT_VELOCITY}
			g.selected = music.track_put(t, n)
			music.song_fit_bars(&g.song, BARS_PER_PAGE)
			g.dirty = true
			player_preview(&g.player, t.inst, p)
		}
		return
	}

	if under >= 0 && ui_take_right(area) {
		undo_push()
		ordered_remove(&t.notes, under)
		g.selected = -1
		g.dirty = true
		return
	}

	// The wheel on a note nudges it a semitone: F -> F# -> G is two clicks,
	// and the spelling follows the direction you went.
	if under >= 0 {
		if w := ui_take_wheel(area); w != 0 {
			g.selected = under
			nudge_selected(w > 0 ? 1 : -1)
		}
	}
}

@(private = "file")
drag_move :: proc(t: ^music.Track, hov: Hover) {
	if g.selected < 0 || g.selected >= len(t.notes) do return
	orig := g.drag.note
	tick := max(snap_tick(max(hov.raw_tick - g.drag.grab + current_snap() / 2, 0)), 0)
	step := hov.step
	cur := &t.notes[g.selected]
	if tick == cur.tick && step == int(cur.pitch.step) do return
	// Accidentals do not travel: a note dragged to another row takes that
	// row's key signature, as on paper. Same row keeps its own spelling.
	p := orig.pitch
	if step != int(orig.pitch.step) do p = music.Pitch{i8(step), music.key_alter(int(g.song.key), step)}
	if !in_range(t.inst, p) do return
	pitch_changed := step != int(cur.pitch.step)
	cur.tick = tick
	cur.pitch = p
	g.drag.moved = true
	if pitch_changed do player_preview(&g.player, t.inst, p)
}

@(private = "file")
drag_finish :: proc(t: ^music.Track) {
	g.drag.active = false
	if !g.drag.moved {
		// Just a click: nothing changed, so the undo step is noise.
		undo_drop_last()
		return
	}
	if g.selected >= 0 && g.selected < len(t.notes) {
		n := t.notes[g.selected]
		ordered_remove(&t.notes, g.selected)
		g.selected = music.track_put(t, n)
	}
	music.song_fit_bars(&g.song, BARS_PER_PAGE)
	g.dirty = true
}

// Move the selected note a semitone, respelling it: up from F is F#, down
// from G is Gb, and a double sharp rolls over to the next letter.
nudge_selected :: proc(dir: int) {
	t := active_track()
	if t == nil || g.selected < 0 || g.selected >= len(t.notes) do return
	n := t.notes[g.selected]
	m := music.pitch_midi(n.pitch) + dir
	p := n.pitch
	p.alter += i8(dir)
	// E#, B#, Fb and Cb are real spellings but not what anyone means by
	// "one semitone up": respell those, and any double accidental, on the
	// neighbouring letter instead.
	letter := int(p.step) % 7
	odd := (p.alter == 1 && (letter == 2 || letter == 6)) || (p.alter == -1 && (letter == 3 || letter == 0))
	if abs(int(p.alter)) > 1 || odd {
		p = music.pitch_from_midi(m, dir > 0 ? 1 : -1)
	}
	if !in_range(t.inst, p) do return
	undo_push()
	t.notes[g.selected].pitch = p
	g.dirty = true
	player_preview(&g.player, t.inst, p)
}

// Move the selected note by staff steps (↑/↓) or slots (←/→).
move_selected :: proc(dstep: int, dslots: i32) {
	t := active_track()
	if t == nil || g.selected < 0 || g.selected >= len(t.notes) do return
	n := t.notes[g.selected]
	step := clamp(int(n.pitch.step) + dstep, sheet_lo(), sheet_hi())
	p := n.pitch
	if dstep != 0 do p = music.Pitch{i8(step), music.key_alter(int(g.song.key), step)}
	tick := max(n.tick + dslots * current_snap(), 0)
	if !in_range(t.inst, p) do return
	undo_push()
	ordered_remove(&t.notes, g.selected)
	n.pitch = p
	n.tick = tick
	g.selected = music.track_put(t, n)
	music.song_fit_bars(&g.song, BARS_PER_PAGE)
	// Follow the note onto another page if it walked off this one.
	g.page = clamp(n.tick / page_ticks(), 0, page_count() - 1)
	g.dirty = true
	if dstep != 0 do player_preview(&g.player, t.inst, p)
}

delete_selected :: proc() {
	t := active_track()
	if t == nil || g.selected < 0 || g.selected >= len(t.notes) do return
	undo_push()
	ordered_remove(&t.notes, g.selected)
	g.selected = -1
	g.dirty = true
}

midi_name :: proc(m: int) -> string {
	return music.pitch_name_temp(music.pitch_from_midi(m, 0))
}

// Copy note `i` of `t` an octave down (dir -1) or up (+1), at the same tick
// and length, spelled the same (F#4 -> F#3). The copy is selected; the
// original stays as it was.
octave_copy :: proc(t: ^music.Track, i: int, dir: int) {
	n := t.notes[i]
	step := int(n.pitch.step) + 7 * dir
	p := music.Pitch{i8(step), n.pitch.alter}
	where_ := dir < 0 ? "lower" : "higher"
	if step < sheet_lo() || step > sheet_hi() || !in_range(t.inst, p) {
		ins := inst_of(t)
		set_error("%s an octave %s is %s: outside the %s's range (%s - %s)", music.pitch_name_temp(n.pitch), where_, music.pitch_name_temp(p), ins.name, midi_name(int(ins.lo)), midi_name(int(ins.hi)))
		return
	}
	undo_push()
	c := n
	c.pitch = p
	g.selected = music.track_put(t, c)
	music.song_fit_bars(&g.song, BARS_PER_PAGE)
	g.dirty = true
	player_preview(&g.player, t.inst, p)
	set_status("copied %s an octave %s: %s", music.pitch_name_temp(n.pitch), where_, music.pitch_name_temp(p))
}

// ---------------------------------------------------------------------------
// Key lines (the "lines" button)
//
// Every row of the sheet is already in the key - it is one row per letter,
// and a click on an F row in G major places F#. So this shows the two things
// that are easy to lose track of instead:
//
//   * the rows the key signature changes: sharp rows tinted warm, flat rows
//     cool, and named F# / Bb in the gutter;
//   * the rows of the key's home chord, the major triad on its tonic: the
//     tonic brightest (every G in G major), the 3rd and 5th (B, D) fainter.
//     A minor key shares its signature with a major one (E minor with G
//     major); this marks the major key's chord.
// ---------------------------------------------------------------------------

KEY_SHARP_ROW :: rl.Color{255, 150, 90, 16}
KEY_FLAT_ROW :: rl.Color{110, 160, 255, 16}
KEY_SHARP_TEXT :: rl.Color{255, 170, 120, 255}
KEY_FLAT_TEXT :: rl.Color{140, 180, 255, 255}

// The letter of the key's tonic (major), C = 0 .. B = 6: each sharp is a
// fifth up (four letters), each flat a fifth down.
key_tonic_letter :: proc() -> int {
	return ((4 * int(g.song.key)) % 7 + 7) % 7
}

@(private = "file")
key_lines_draw :: proc() {
	tonic := key_tonic_letter()
	for step in sheet_lo() ..= sheet_hi() {
		r := rect(BARS_X, row_y(step), BARS_W, row_h())
		switch music.key_alter(int(g.song.key), step) {
		case 1:
			fill(r, KEY_SHARP_ROW)
		case -1:
			fill(r, KEY_FLAT_ROW)
		}
		switch (step % 7 - tonic + 7) % 7 {
		case 0:
			fill(r, with_alpha(COL_ACCENT, 30))
			rl.DrawLineEx({r.x, r.y + 0.5}, {r.x + r.width, r.y + 0.5}, 1, with_alpha(COL_ACCENT, 50))
			rl.DrawLineEx({r.x, r.y + r.height - 0.5}, {r.x + r.width, r.y + r.height - 0.5}, 1, with_alpha(COL_ACCENT, 50))
		case 2, 4:
			fill(r, with_alpha(COL_ACCENT, 13))
		}
	}
}

// ---------------------------------------------------------------------------
// Ratios (with key lines on): each row's frequency against a reference note,
// as the small whole-number ratio the interval is heard as - the octave 2:1,
// the fifth 3:2, the major third 5:4 (just intonation, 5-limit). With C5 as
// the reference, C6 reads 2:1, G5 3:2, E5 5:4, G4 3:4, C4 1:2.
//
// The reference is the key's tonic at or just below the first note of the
// layer being edited (C4's octave for an empty layer); right-click a row in
// the gutter to pick another, right-click it again to go back to automatic.
// ---------------------------------------------------------------------------

// The pitch a row plays in this key.
key_pitch :: proc(step: int) -> music.Pitch {
	return {i8(step), music.key_alter(int(g.song.key), step)}
}

ratio_ref_step :: proc() -> int {
	if g.ratio_ref >= 0 do return int(g.ratio_ref)
	tonic := key_tonic_letter()
	top := 28 + 6 // B4: the tonic in middle C's octave if the layer is empty
	if t := active_track(); t != nil && len(t.notes) > 0 {
		top = int(t.notes[0].pitch.step)
	}
	step := top
	for step > sheet_lo() && step % 7 != tonic do step -= 1
	if step % 7 != tonic do step += 7
	return step
}

// Just intonation for each semitone above the reference.
@(private = "file")
JUST := [12][2]int {
	{1, 1}, {16, 15}, {9, 8}, {6, 5}, {5, 4}, {4, 3},
	{45, 32}, {3, 2}, {8, 5}, {5, 3}, {9, 5}, {15, 8},
}

// "3:2" for the fifth above the reference. `octave`: a whole number of
// octaves (1:1, 2:1, 1:2...). Rows more than three octaves away get none.
key_ratio :: proc(step: int) -> (s: string, octave: bool, ok: bool) {
	ref := music.pitch_midi(key_pitch(ratio_ref_step()))
	semis := music.pitch_midi(key_pitch(step)) - ref
	oct := semis >= 0 ? semis / 12 : -((-semis + 11) / 12)
	within := semis - oct * 12
	if oct > 3 || oct < -3 do return "", false, false
	num, den := JUST[within][0], JUST[within][1]
	if oct >= 0 do num <<= uint(oct)
	else do den <<= uint(-oct)
	a, b := num, den
	for b != 0 do a, b = b, a % b
	return fmt.tprintf("%d:%d", num / a, den / a), within == 0, true
}
