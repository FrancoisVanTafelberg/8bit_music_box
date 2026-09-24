package app

/*
    Everything around the sheet: the top bar (song settings, transport, file),
    the layer panel on the left, the status line, the two overlays (instrument
    picker, open file), the keyboard, and undo.
*/

import "core:fmt"
import "core:strings"
import "music"
import rl "vendor:raylib"

Overlay :: enum {
	None,
	Instruments,
	Open,
}

overlay_none :: proc() -> bool {
	return g.overlay == .None
}

TIME_SIGS := [?][2]i32{{4, 4}, {3, 4}, {2, 4}, {2, 2}, {6, 8}, {9, 8}, {12, 8}, {5, 4}}

// ---------------------------------------------------------------------------
// Top bar
// ---------------------------------------------------------------------------

topbar_draw :: proc() {
	fill(rect(0, 0, 1280, TOP_H), COL_PANEL)
	rl.DrawLine(0, TOP_H - 1, 1280, TOP_H - 1, COL_EDGE)
	y := f32(6)
	h := f32(20)

	// Title: click to type.
	tr := rect(8, y, 196, h)
	fill(tr, g.editing_title ? COL_PANEL_HI : COL_SHEET)
	outline(tr, g.editing_title ? COL_ACCENT : COL_EDGE)
	title := g.editing_title ? string(g.title_buf[:g.title_len]) : g.song.title
	shown := fit_text(title, tr.width - 12)
	if g.editing_title && (g.frames / 30) % 2 == 0 do shown = strings.concatenate({shown, "_"}, context.temp_allocator)
	text(shown, tr.x + 5, tr.y + 5, COL_TEXT)
	if g.dirty do text("*", tr.x + tr.width - 8, tr.y + 5, COL_ACCENT)
	if !g.editing_title && ui_take_click(tr) do title_begin()

	// Tempo.
	x := f32(214)
	label("tempo", x, y + 5)
	x += 34
	step := rl.IsKeyDown(.LEFT_SHIFT) ? f32(10) : f32(1)
	if button(rect(x, y, 18, h), "-") {g.song.tempo = max(g.song.tempo - step, 20); g.dirty = true}
	text_centered(fmt.tprintf("%v", g.song.tempo), rect(x + 18, y, 34, h))
	if button(rect(x + 52, y, 18, h), "+") {g.song.tempo = min(g.song.tempo + step, 400); g.dirty = true}
	x += 78

	// Time signature: click cycles.
	label("time", x, y + 5)
	x += 26
	if button(rect(x, y, 40, h), fmt.tprintf("%d/%d", g.song.beats, g.song.beat_unit)) {
		idx := 0
		for ts, i in TIME_SIGS do if ts[0] == g.song.beats && ts[1] == g.song.beat_unit do idx = i
		next := TIME_SIGS[(idx + 1) % len(TIME_SIGS)]
		g.song.beats, g.song.beat_unit = next[0], next[1]
		music.song_fit_bars(&g.song, BARS_PER_PAGE)
		g.page = clamp(g.page, 0, page_count() - 1)
		g.dirty = true
	}
	x += 48

	// Key signature.
	label("key", x, y + 5)
	x += 20
	if button(rect(x, y, 18, h), "-") && g.song.key > -7 {g.song.key -= 1; g.dirty = true}
	key_label := g.song.key == 0 ? "C major" : fmt.tprintf("%s %d%s", music.key_name(int(g.song.key)), abs(g.song.key), g.song.key > 0 ? "#" : "b")
	text_centered(key_label, rect(x + 18, y, 92, h))
	if button(rect(x + 110, y, 18, h), "+") && g.song.key < 7 {g.song.key += 1; g.dirty = true}
	x += 138

	// Transport.
	if button(rect(x, y, 56, h), g.player.playing ? "Stop" : "Play", g.player.playing) do toggle_play(rl.IsKeyDown(.LEFT_SHIFT))
	x += 60
	if button(rect(x, y, 30, h), "|<") {player_stop(&g.player); g.page = 0}
	x += 34
	if button(rect(x, y, 50, h), "Follow", g.follow) do g.follow = !g.follow
	x += 54
	if button(rect(x, y, 50, h), "4-bit", g.crush) do g.crush = !g.crush
	x += 64

	// File.
	if button(rect(x, y, 40, h), "New") do file_new()
	x += 44
	if button(rect(x, y, 40, h), "Open") do open_overlay()
	x += 44
	if button(rect(x, y, 40, h), "Save") do file_save()
	x += 52
	label("export", x, y + 5)
	x += 38
	if button(rect(x, y, 36, h), "WAV") do file_export("wav")
	x += 40
	for fmt_name in ([3]string{"mp3", "ogg", "flac"}) {
		if button(rect(x, y, 36, h), strings.to_upper(fmt_name, context.temp_allocator), false, g.has_ffmpeg) do file_export(fmt_name)
		x += 40
	}
}

@(private = "file")
title_begin :: proc() {
	g.editing_title = true
	n := min(len(g.song.title), len(g.title_buf))
	copy(g.title_buf[:], g.song.title[:n])
	g.title_len = n
}

@(private = "file")
title_end :: proc(keep: bool) {
	g.editing_title = false
	s := strings.trim_space(string(g.title_buf[:g.title_len]))
	if keep && len(s) > 0 && s != g.song.title {
		music.song_set_title(&g.song, s)
		g.dirty = true
	}
}

// ---------------------------------------------------------------------------
// Left panel
// ---------------------------------------------------------------------------

LAYER_ROWS :: 12
LAYER_H :: 20

panel_draw :: proc() {
	fill(rect(0, TOP_H, PANEL_W, 720 - TOP_H - STATUS_H), COL_PANEL)
	rl.DrawLine(PANEL_W - 1, TOP_H, PANEL_W - 1, 720 - STATUS_H, COL_EDGE)
	x := f32(8)
	w := f32(PANEL_W - 16)
	y := f32(TOP_H + 8)

	label("LAYERS", x, y)
	text(fmt.tprintf("%d", len(g.song.tracks)), x + w - 12, y, COL_FAINT)
	y += 14

	list := rect(x, y, w, LAYER_ROWS * LAYER_H)
	fill(list, COL_SHEET)
	n := len(g.song.tracks)
	if wh := ui_take_wheel(list); wh != 0 do g.layer_scroll -= int(wh)
	g.layer_scroll = clamp(g.layer_scroll, 0, max(n - LAYER_ROWS, 0))
	for row in 0 ..< LAYER_ROWS {
		i := g.layer_scroll + row
		if i >= n do break
		t := &g.song.tracks[i]
		r := rect(x, y + f32(row) * LAYER_H, w, LAYER_H - 1)
		on := i == g.active
		fill(r, on ? COL_PANEL_HI : (hovered(r) ? COL_BUTTON : COL_SHEET))
		if on do outline(r, COL_ACCENT)
		fill(rect(r.x + 4, r.y + 5, 9, 9), inst_color(inst_of(t).color))
		audible := music.track_audible(&g.song, t)
		text(fit_text(t.name, w - 64), r.x + 18, r.y + 5, audible ? COL_TEXT : COL_FAINT)
		mr := rect(r.x + w - 40, r.y + 2, 18, 15)
		sr := rect(r.x + w - 20, r.y + 2, 18, 15)
		if button(mr, "M", t.mute) {t.mute = !t.mute; g.dirty = true}
		if button(sr, "S", t.solo) {t.solo = !t.solo; g.dirty = true}
		if ui_take_click(r) do select_layer(i)
	}
	if n > LAYER_ROWS {
		text(fmt.tprintf("%d-%d of %d  (wheel)", g.layer_scroll + 1, min(g.layer_scroll + LAYER_ROWS, n), n), x, y + list.height + 2, COL_FAINT)
	}
	y += list.height + 14

	when CELLO {
		// The Cello Helper has one instrument: another layer is another cello.
		if button(rect(x, y, w, 20), "+ Add cello layer") {
			i := music.song_add_track(&g.song, music.inst_or_default(&g.song, CELLO_KEY))
			select_layer(i)
			g.dirty = true
			set_status("added %s", g.song.tracks[i].name)
		}
	} else {
		if button(rect(x, y, w, 20), "+ Add instrument") do g.overlay = .Instruments
	}
	y += 24
	if button(rect(x, y, w, 20), "Remove layer", false, n > 0) {
		if confirmed("remove-layer", fmt.tprintf("Remove the %s layer and its notes?", g.song.tracks[g.active].name)) {
			// The engine counts layers by position: stop before they shift.
			player_stop(&g.player)
			music.song_remove_track(&g.song, g.active)
			g.active = clamp(g.active, 0, len(g.song.tracks) - 1)
			g.selected = -1
			undo_clear()
			g.dirty = true
		}
	}
	y += 30

	// Note length.
	label("LENGTH  (1-6, . dotted, T triplet)", x, y)
	y += 14
	bw := (w - 8) / 3
	for l, i in music.Length {
		r := rect(x + f32(i % 3) * (bw + 4), y + f32(i / 3) * 24, bw, 20)
		if button(r, music.LENGTH_LABEL[l], g.length == l) do g.length = l
	}
	y += 48
	hw := (w - 4) / 2
	if button(rect(x, y, hw, 20), "Dotted", g.mod == .Dotted) do g.mod = g.mod == .Dotted ? .None : .Dotted
	if button(rect(x + hw + 4, y, hw, 20), "Triplet", g.mod == .Triplet) do g.mod = g.mod == .Triplet ? .None : .Triplet
	y += 30

	// Accidental mode.
	label("ACCIDENTAL  (or hold Shift # / Ctrl b)", x, y)
	y += 14
	qw := (w - 12) / 4
	names := [Acc_Mode]string{.Key = "key", .Sharp = "#", .Flat = "b", .Natural = "nat"}
	for m, i in Acc_Mode {
		if button(rect(x + f32(i) * (qw + 4), y, qw, 20), names[m], g.acc_mode == m) do g.acc_mode = m
	}
	y += 30

	// The active instrument.
	if t := active_track(); t != nil {
		ins := inst_of(t)
		fill(rect(x, y, w, 120), COL_SHEET)
		outline(rect(x, y, w, 120), COL_EDGE)
		fill(rect(x, y, 4, 120), inst_color(ins.color))
		text(ins.name, x + 10, y + 6, COL_TEXT, FONT_BIG)
		text(music.FAMILY_NAME[ins.family], x + 10, y + 28, COL_DIM)
		text(fmt.tprintf("range  %s - %s", midi_name(int(ins.lo)), midi_name(int(ins.hi))), x + 10, y + 42, COL_TEXT)
		text(fmt.tprintf("sound  %s", wave_desc(ins)), x + 10, y + 56, COL_DIM)
		text("volume", x + 10, y + 76, COL_DIM)
		if button(rect(x + 56, y + 72, 18, 16), "-") {t.volume = max(t.volume - 0.1, 0); g.dirty = true}
		text_centered(fmt.tprintf("%d%%", int(t.volume * 100 + 0.5)), rect(x + 74, y + 72, 40, 16))
		if button(rect(x + 114, y + 72, 18, 16), "+") {t.volume = min(t.volume + 0.1, 2); g.dirty = true}
		if button(rect(x + 140, y + 72, 40, 16), "hear") do player_preview(&g.player, t.inst, music.pitch_from_midi(int(ins.lo + ins.hi) / 2, int(g.song.key)))
		// Where the definition lives, and a way to make the song carry it.
		switch ins.origin {
		case .Fallback:
			text("no instrument files!", x + 10, y + 98, COL_BAD)
		case .File:
			text(fit_text(fmt.tprintf("file: %s", ins.source), w - 70), x + 10, y + 98, COL_DIM)
		case .Song:
			text("defined in this song", x + 10, y + 98, COL_GOOD)
		}
		if ins.origin != .Song && button(rect(x + w - 56, y + 94, 50, 16), "embed") {
			key := ins.key
			music.song_embed_instrument(&g.song, t.inst)
			g.dirty = true
			set_status("%s is now defined inside this song: it plays the same on any copy of the app", key)
		}
	}
}

select_layer :: proc(i: int) {
	if i < 0 || i >= len(g.song.tracks) do return
	if i != g.active do g.selected = -1
	g.active = i
	if i < g.layer_scroll do g.layer_scroll = i
	if i >= g.layer_scroll + LAYER_ROWS do g.layer_scroll = i - LAYER_ROWS + 1
}

@(private = "file")
wave_desc :: proc(ins: ^music.Instrument) -> string {
	one :: proc(w: music.Wave, duty: f32) -> string {
		switch w {
		case .Pulse:
			return fmt.tprintf("pulse %v%%", duty * 100)
		case .Triangle:
			return "triangle"
		case .Saw:
			return "saw"
		case .Sine:
			return "sine"
		case .Noise:
			return "noise"
		}
		return ""
	}
	s := one(ins.wave, ins.duty)
	if ins.mix2 > 0 do s = fmt.tprintf("%s + %s", s, one(ins.wave2, ins.duty))
	return s
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

statusbar_draw :: proc() {
	y := f32(720 - STATUS_H)
	fill(rect(0, y, 1280, STATUS_H), COL_PANEL)
	rl.DrawLine(0, i32(y), 1280, i32(y), COL_EDGE)

	msg := status_text()
	age := rl.GetTime() - g.status_time
	fb_msg, on_board := "", false
	when CELLO do fb_msg, on_board = fingerboard_status()
	if on_board {
		text(fb_msg, 8, y + 5, COL_TEXT)
		return
	}
	if len(msg) > 0 && age < 6 {
		text(msg, 8, y + 5, g.status_bad ? COL_BAD : COL_GOOD)
	} else if hov := sheet_hover(); hov.ok {
		p := placed_pitch(hov.step)
		bt := music.bar_ticks(&g.song)
		bar := hov.tick / bt
		beat := (hov.tick - bar * bt) / music.beat_ticks(&g.song)
		sub := (hov.tick - bar * bt) % music.beat_ticks(&g.song)
		f := music.midi_freq(f32(music.pitch_midi(p)))
		text(
			fmt.tprintf("%s   %.1f Hz   bar %d  beat %d%s", music.pitch_name_temp(p), f, bar + 1, beat + 1, sub != 0 ? fmt.tprintf(" +%d/%d", sub, music.beat_ticks(&g.song)) : ""),
			8,
			y + 5,
			COL_TEXT,
		)
	}
	hint := "click place   drag move   right-click delete   wheel sharp/flat   Space play   PgUp/PgDn page   Ctrl+Z undo"
	when CELLO do hint = "click place   right-click delete   wheel sharp/flat   Space play   click the fingerboard to hear"
	text(hint, 1280 - text_width(hint) - 8, y + 5, COL_FAINT)
}

// ---------------------------------------------------------------------------
// Overlays
// ---------------------------------------------------------------------------

overlay_draw :: proc() {
	switch g.overlay {
	case .None:
		return
	case .Instruments:
		instruments_overlay()
	case .Open:
		open_overlay_draw()
	}
	// Whatever the overlay did not take, nobody underneath gets.
	if g.ui.clicked || g.ui.right {
		g.overlay = .None
		ui_take_all()
	}
	ui_take_all()
}

@(private = "file")
instruments_overlay :: proc() {
	r := rect(PANEL_W + 20, TOP_H + 20, 1280 - PANEL_W - 40, 520)
	fill(rect(0, 0, 1280, 720), {0, 0, 0, 150})
	fill(r, COL_PANEL)
	outline(r, COL_ACCENT)
	text("Add an instrument layer", r.x + 12, r.y + 10, COL_TEXT, FONT_BIG)
	text("Instruments come from the .inst files in instruments/ (F7 reloads them)   (song) = defined in this song   Esc closes", r.x + 12, r.y + 34, COL_DIM)
	colw := (r.width - 24) / f32(len(music.Family))
	for fam, fi in music.Family {
		cx := r.x + 12 + f32(fi) * colw
		cy := r.y + 60
		text(music.FAMILY_NAME[fam], cx, cy, COL_ACCENT)
		cy += 16
		// The registry (built-in, then instrument files), then the song's own.
		// A song definition hides a registry one with the same key.
		pick :: proc(ins: ^music.Instrument, id: music.Inst_Id, cx, cy, w: f32) {
			label := ins.name
			if ins.origin == .Song do label = fmt.tprintf("%s (song)", ins.name)
			br := rect(cx, cy, w, 22)
			if button(br, label) {
				i := music.song_add_track(&g.song, id)
				select_layer(i)
				g.overlay = .None
				g.dirty = true
				set_status("added %s  (%s - %s)", ins.name, midi_name(int(ins.lo)), midi_name(int(ins.hi)))
			}
			fill(rect(br.x + 2, br.y + 2, 4, br.height - 4), inst_color(ins.color))
		}
		for &ins, i in music.reg().list {
			if ins.family != fam do continue
			shadowed := false
			for d in g.song.defs do if d.key == ins.key do shadowed = true
			if shadowed do continue
			pick(&ins, music.Inst_Id(i), cx, cy, colw - 8)
			cy += 26
		}
		for &ins, i in g.song.defs {
			if ins.family != fam do continue
			pick(&ins, music.SONG_INST_BASE + music.Inst_Id(i), cx, cy, colw - 8)
			cy += 26
		}
	}
	// Clicks inside the panel but on no button are not "outside".
	if hovered(r) do ui_take_all()
}

open_overlay :: proc() {
	files_scan()
	g.overlay = .Open
}

@(private = "file")
open_overlay_draw :: proc() {
	r := rect(PANEL_W + 20, TOP_H + 20, 1280 - PANEL_W - 40, 560)
	fill(rect(0, 0, 1280, 720), {0, 0, 0, 150})
	fill(r, COL_PANEL)
	outline(r, COL_ACCENT)
	text("Open", r.x + 12, r.y + 10, COL_TEXT, FONT_BIG)
	when CELLO {
		text("[cello] = cello_songs/, where this saves. Songs from songs/ and MIDI open with every layer turned into a cello, and save to cello_songs/.", r.x + 12, r.y + 34, COL_DIM)
	} else {
		text("Songs from songs/, MIDI from imports/, [private] = not public domain. Or drag a .song / .mid onto the window.", r.x + 12, r.y + 34, COL_DIM)
	}
	if len(g.open_files) == 0 {
		text("Nothing here yet. Save a song, or put a .mid file in imports/.", r.x + 12, r.y + 70, COL_TEXT)
	}
	cols := 3
	colw := (r.width - 24) / f32(cols)
	per_col := 20
	for f, i in g.open_files {
		if i >= cols * per_col do break
		cx := r.x + 12 + f32(i / per_col) * colw
		cy := r.y + 60 + f32(i % per_col) * 24
		name := f
		if k := strings.last_index_any(name, "/\\"); k >= 0 do name = name[k + 1:]
		is_midi := !strings.has_suffix(name, music.SONG_EXT)
		shown := is_midi ? fmt.tprintf("[midi] %s", name) : name
		if strings.contains(f, PRIVATE_DIR) do shown = fmt.tprintf("[private] %s", shown)
		when CELLO do if strings.contains(f, CELLO_DIR) do shown = fmt.tprintf("[cello] %s", shown)
		if button(rect(cx, cy, colw - 8, 20), shown) {
			if !g.dirty || confirmed(f, "Unsaved changes will be lost") {
				g.overlay = .None
				file_open(f)
			}
		}
	}
	if hovered(r) do ui_take_all()
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

keys_update :: proc() {
	ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)

	if g.editing_title {
		for c := rl.GetCharPressed(); c != 0; c = rl.GetCharPressed() {
			if c >= 32 && c < 127 && g.title_len < len(g.title_buf) {
				g.title_buf[g.title_len] = u8(c)
				g.title_len += 1
			}
		}
		if (rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE)) && g.title_len > 0 do g.title_len -= 1
		if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) do title_end(true)
		if rl.IsKeyPressed(.ESCAPE) do title_end(false)
		if g.ui.clicked && !hovered(rect(8, 6, 196, 20)) do title_end(true)
		return
	}

	if rl.IsKeyPressed(.ESCAPE) {
		if g.overlay != .None do g.overlay = .None
		else do g.selected = -1
	}
	if g.overlay != .None do return

	if ctrl {
		if rl.IsKeyPressed(.S) do file_save()
		if rl.IsKeyPressed(.O) do open_overlay()
		if rl.IsKeyPressed(.N) do file_new()
		if rl.IsKeyPressed(.E) do file_export("wav")
		if rl.IsKeyPressed(.Z) || rl.IsKeyPressedRepeat(.Z) {if shift do redo(); else do undo()}
		if rl.IsKeyPressed(.Y) || rl.IsKeyPressedRepeat(.Y) do redo()
		return
	}

	if rl.IsKeyPressed(.SPACE) do toggle_play(shift)

	for key, i in ([6]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR, .FIVE, .SIX}) {
		if rl.IsKeyPressed(key) do g.length = music.Length(i)
	}
	if rl.IsKeyPressed(.PERIOD) do g.mod = g.mod == .Dotted ? .None : .Dotted
	if rl.IsKeyPressed(.T) do g.mod = g.mod == .Triplet ? .None : .Triplet
	if rl.IsKeyPressed(.TAB) && len(g.song.tracks) > 0 {
		select_layer((g.active + (shift ? len(g.song.tracks) - 1 : 1)) % len(g.song.tracks))
	}

	// Pages.
	if rl.IsKeyPressed(.PAGE_DOWN) || rl.IsKeyPressed(.RIGHT_BRACKET) do g.page = min(g.page + 1, page_count() - 1)
	if rl.IsKeyPressed(.PAGE_UP) || rl.IsKeyPressed(.LEFT_BRACKET) do g.page = max(g.page - 1, 0)
	if rl.IsKeyPressed(.HOME) do g.page = 0
	if rl.IsKeyPressed(.END) do g.page = page_count() - 1

	// The selected note, or the page when nothing is selected.
	pressed :: proc(k: rl.KeyboardKey) -> bool {return rl.IsKeyPressed(k) || rl.IsKeyPressedRepeat(k)}
	if g.selected >= 0 {
		if pressed(.UP) {if shift do nudge_selected(1); else do move_selected(1, 0)}
		if pressed(.DOWN) {if shift do nudge_selected(-1); else do move_selected(-1, 0)}
		if pressed(.LEFT) do move_selected(0, -1)
		if pressed(.RIGHT) do move_selected(0, 1)
		if rl.IsKeyPressed(.DELETE) || rl.IsKeyPressed(.BACKSPACE) do delete_selected()
	} else {
		if pressed(.RIGHT) do g.page = min(g.page + 1, page_count() - 1)
		if pressed(.LEFT) do g.page = max(g.page - 1, 0)
	}
}

// ---------------------------------------------------------------------------
// Undo: snapshots of one layer's notes. Cheap - a layer is a few thousand
// notes of 12 bytes - and impossible to get subtly wrong the way recorded
// operations can be.
// ---------------------------------------------------------------------------

UNDO_MAX :: 200

Undo :: struct {
	track: int,
	notes: []music.Note,
}

@(private = "file")
snapshot :: proc(track: int) -> Undo {
	t := &g.song.tracks[track]
	notes := make([]music.Note, len(t.notes))
	copy(notes, t.notes[:])
	return {track, notes}
}

undo_push :: proc() {
	if g.active < 0 || g.active >= len(g.song.tracks) do return
	append(&g.undo, snapshot(g.active))
	if len(g.undo) > UNDO_MAX {
		delete(g.undo[0].notes)
		ordered_remove(&g.undo, 0)
	}
	for u in g.redo do delete(u.notes)
	clear(&g.redo)
}

undo_drop_last :: proc() {
	if len(g.undo) == 0 do return
	u := pop(&g.undo)
	delete(u.notes)
}

undo_clear :: proc() {
	for u in g.undo do delete(u.notes)
	for u in g.redo do delete(u.notes)
	clear(&g.undo)
	clear(&g.redo)
}

@(private = "file")
restore :: proc(from, to: ^[dynamic]Undo) {
	if len(from) == 0 do return
	u := pop(from)
	if u.track >= len(g.song.tracks) {
		delete(u.notes)
		return
	}
	append(to, snapshot(u.track))
	t := &g.song.tracks[u.track]
	clear(&t.notes)
	append(&t.notes, ..u.notes)
	delete(u.notes)
	select_layer(u.track)
	g.selected = -1
	g.dirty = true
}

undo :: proc() {restore(&g.undo, &g.redo)}
redo :: proc() {restore(&g.redo, &g.undo)}
