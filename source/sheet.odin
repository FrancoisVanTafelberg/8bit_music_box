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

BARS_PER_PAGE :: 4

TOP_H :: 32
STATUS_H :: 20
PANEL_W :: 208
GUTTER_W :: 44
BARS_X :: PANEL_W + GUTTER_W
BARS_W :: 1280 - BARS_X - 8
BAR_NUM_Y :: TOP_H + 2
ROWS_Y :: TOP_H + 18
ROW_H :: 12
ROWS_H :: music.STEP_COUNT * ROW_H
STRIP_Y :: ROWS_Y + ROWS_H + 4
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
	return f32(ROWS_Y + (music.STEP_HI - step) * ROW_H)
}

row_center :: proc(step: int) -> f32 {
	return row_y(step) + ROW_H / 2
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

active_track :: proc() -> ^music.Track {
	if g.active < 0 || g.active >= len(g.song.tracks) do return nil
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
	if m.x < BARS_X || m.x >= BARS_X + BARS_W || m.y < ROWS_Y || m.y >= ROWS_Y + ROWS_H do return {}
	h: Hover
	h.ok = true
	h.step = music.STEP_HI - int((m.y - ROWS_Y) / ROW_H)
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

in_range :: proc(inst: music.Inst, p: music.Pitch) -> bool {
	ins := &music.INSTRUMENTS[inst]
	m := i32(music.pitch_midi(p))
	return m >= ins.lo && m <= ins.hi
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

sheet_draw :: proc() {
	fill(rect(PANEL_W, TOP_H, 1280 - PANEL_W, 720 - TOP_H - STATUS_H), COL_SHEET)
	t := active_track()
	bt := music.bar_ticks(&g.song)
	ps := page_start()
	right := f32(BARS_X + BARS_W)

	// Rows the active instrument cannot play: shaded, so the playable band
	// stands out as the lit part of the page.
	if t != nil {
		for step in music.STEP_LO ..= music.STEP_HI {
			p := music.Pitch{i8(step), music.key_alter(int(g.song.key), step)}
			if !in_range(t.inst, p) {
				fill(rect(BARS_X, row_y(step), BARS_W, ROW_H), {8, 9, 16, 255})
			}
		}
	}

	// The hovered row, faintly, all the way across.
	hov := sheet_hover()
	if hov.ok do fill(rect(PANEL_W, row_y(hov.step), 1280 - PANEL_W, ROW_H), {255, 255, 255, 10})

	// Staff lines.
	for step in music.STEP_LO ..= music.STEP_HI {
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
	top, bottom := f32(ROWS_Y), f32(ROWS_Y + ROWS_H)
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
		text(fmt.tprintf("%d", bar + 1), bx + 3, BAR_NUM_Y, bar < g.song.bars ? COL_DIM : COL_FAINT)
	}
	rl.DrawLineEx({right, top}, {right, bottom}, 2, {170, 170, 214, 255})

	gutter_draw(hov)

	// Notes: the other layers first and dim, the active one last and bright.
	playing_tick := g.player.playing ? player_tick(&g.player, &g.song) : -1
	for &tr, i in g.song.tracks do if i != g.active do notes_draw(&tr, false, playing_tick)
	if t != nil do notes_draw(t, true, playing_tick)

	// The ghost of the note a click would place.
	if hov.ok && t != nil && !g.drag.active && overlay_none() {
		if music.track_note_at(t, hov.step, hov.raw_tick) < 0 {
			p := placed_pitch(hov.step)
			col := inst_color(music.INSTRUMENTS[t.inst].color)
			if !in_range(t.inst, p) do col = COL_BAD
			x0 := tick_x(hov.tick)
			w := f32(music.note_ticks(g.length, g.mod)) * px_per_tick()
			fill(rect(x0, row_center(hov.step) - 5, max(w - 1, 3), 10), with_alpha(col, 70))
			outline(rect(x0, row_center(hov.step) - 5, max(w - 1, 3), 10), with_alpha(col, 160))
		}
	}

	// The playhead.
	if g.player.playing && playing_tick >= ps && playing_tick < ps + page_ticks() {
		x := tick_x(playing_tick)
		rl.DrawLineEx({x, top - 4}, {x, bottom}, 2, COL_ACCENT)
	}

	strip_draw()
}

@(private = "file")
notes_draw :: proc(t: ^music.Track, active: bool, playing_tick: i32) {
	ins := &music.INSTRUMENTS[t.inst]
	base := inst_color(ins.color)
	ps := page_start()
	pe := ps + page_ticks()
	left, right := f32(BARS_X), f32(BARS_X + BARS_W)
	muted := !music.track_audible(&g.song, t)

	for n, i in t.notes {
		if n.tick >= pe do break
		if n.tick + n.len <= ps do continue
		step := int(n.pitch.step)
		if step < music.STEP_LO || step > music.STEP_HI do continue
		x0 := max(tick_x(n.tick), left)
		x1 := min(tick_x(n.tick + n.len), right)
		yc := row_center(step)
		sounding := playing_tick >= n.tick && playing_tick < n.tick + n.len && !muted

		col := base
		if !active do col = with_alpha(base, muted ? 40 : 95)
		if active && muted do col = with_alpha(base, 150)
		if sounding do col = lighten(base, 0.55)

		// The body: how long it lasts. The head: where it starts, a square
		// pixel block, because this is an 8-bit music box.
		fill(rect(x0 + 1, yc - 3, max(x1 - x0 - 2, 1), 6), col)
		if tick_x(n.tick) >= left {
			head := rect(x0, yc - 5, min(10, max(x1 - x0, 4)), 10)
			fill(head, active || sounding ? lighten(col, 0.2) : col)
			if active do outline(head, {0, 0, 0, 120})
		}
		if sounding do outline(rect(x0 - 1, yc - 6, x1 - x0 + 2, 12), rl.WHITE)
		if active && i == g.selected do outline(rect(x0 - 2, yc - 7, x1 - x0 + 4, 14), COL_ACCENT)

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

// Note names down the left of the sheet, and the clef marks.
@(private = "file")
gutter_draw :: proc(hov: Hover) {
	x := f32(PANEL_W)
	fill(rect(x, ROWS_Y, GUTTER_W, ROWS_H), COL_PANEL)
	for step in music.STEP_LO ..= music.STEP_HI {
		y := row_y(step)
		letter := step % 7
		name := music.pitch_name_temp({i8(step), 0})
		is_c := letter == 0
		c := is_c ? COL_TEXT : COL_FAINT
		if hov.ok && hov.step == step do c = COL_ACCENT
		if is_c || (hov.ok && hov.step == step) {
			text(name, x + 20, y + 1, c)
		} else {
			text(name[:1], x + 20, y + 1, c)
		}
		if is_c do rl.DrawLineEx({x + 18, y + ROW_H}, {x + GUTTER_W, y + ROW_H}, 1, COL_EDGE)
	}
	// Clef marks where each clef's own line is: G on G4, C on C4, F on F3.
	clef :: proc(step: int, s: string) {
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
	w := min(f32(BARS_W - 30) / f32(n), 48)
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
					fill(rect(r.x + 2, r.y + 2, 4, 4), inst_color(music.INSTRUMENTS[t.inst].color))
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

	// The piano gutter: click to hear a row.
	gut := rect(PANEL_W, ROWS_Y, GUTTER_W, ROWS_H)
	if ui_take_click(gut) {
		step := music.STEP_HI - int((g.ui.mouse.y - ROWS_Y) / ROW_H)
		player_preview(&g.player, t.inst, placed_pitch(step))
	}

	if !hov.ok do return
	area := rect(BARS_X, ROWS_Y, BARS_W, ROWS_H)
	under := music.track_note_at(t, hov.step, hov.raw_tick)

	if ui_take_click(area) {
		if under >= 0 {
			// Grab it: select, hear it, and be ready to drag.
			g.selected = under
			n := t.notes[under]
			undo_push()
			g.drag = {active = true, note = n, grab = hov.raw_tick - n.tick}
			player_preview(&g.player, t.inst, n.pitch)
		} else {
			p := placed_pitch(hov.step)
			if !in_range(t.inst, p) {
				ins := music.INSTRUMENTS[t.inst]
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
	step := clamp(int(n.pitch.step) + dstep, music.STEP_LO, music.STEP_HI)
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
