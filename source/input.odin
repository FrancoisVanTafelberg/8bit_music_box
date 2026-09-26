package app

/*
    Input mode: play along on a real instrument, and see what you played.

    Switch it on (the Mic button under the sheet, or I) and the microphone is
    listened to (mic_windows.odin); what note is sounding is worked out as it
    comes in (music/pitch.odin: band-pass, a noise gate that learns the room,
    YIN), and shown:

      * as a big dot on the sheet, in the colour opposite the layer's, on the
        row of the note, a little above or below the row's middle when the
        note is sharp or flat (with the name and cents beside it). Stopped,
        it sits on the bar cursor; playing, it rides the playhead;
      * in the Cello Helper, on the fingerboard too, where the note is played
        (chosen as the tracking mode would), slid along the string by how
        sharp or flat it is;
      * and while the song plays, as a line drawn behind the playhead: the
        take. It stays on the sheet until Play is pressed again or Reset.

    Play scope (the button beside Mic): the whole song, one bar from the
    cursor, or the page. Bar and Page stop at their end, and the cursor stays
    where it was, so Play again goes round the same bar.

    Where the take is drawn in time: each reading knows how long ago the
    sound it describes was heard (music.Pitch_Reading.delay), and the
    Latency setting adds what the sound card and Windows take on top (40 ms
    is typical; turn it up if the line lags the notes it should sit on).
*/

import "core:fmt"
import "core:math"
import "music"
import rl "vendor:raylib"

MIC_BUF :: 512 // samples a buffer: 23 ms
MIC_BUFS :: 8 // ...eight of them queued: 186 ms before anything is lost
MIC_MAX_DEVICES :: 16
MIC_LATENCY_DEFAULT :: 40 // ms

Mic_Device :: struct {
	name: [64]u8,
	len:  int,
}

Play_Scope :: enum u8 {
	Song,
	Bar,
	Page,
}

SCOPE_NAME := [Play_Scope]string {
	.Song = "Song",
	.Bar  = "Bar",
	.Page = "Page",
}

Take_Point :: struct {
	tick: f32, // where in the song (fractional ticks)
	midi: f32, // 0 = nothing played
}

Input :: struct {
	on:          bool,
	device:      int, // -1 = the system's default
	devices:     [MIC_MAX_DEVICES]Mic_Device,
	n_devices:   int,
	listed:      bool,
	os:          Mic_Os,
	open:        bool,
	det:         music.Pitch_Detector,
	latency_ms:  f32,
	sensitivity: f32,
	// Now: the note being played (0 = none), and when it was last heard.
	midi:        f32,
	heard_at:    f64,
	// The fingerboard place it is shown at, kept from note to note so the
	// tracking mode can choose the next one from it.
	fb_pos:      Fb_Pos,
	fb_midi:     int,
	// What was played along with the song: until Play or Reset.
	take:        [dynamic]Take_Point,
	scope:       Play_Scope,
}

input_init :: proc() {
	in_ := &g.input
	in_.device = -1
	in_.latency_ms = MIC_LATENCY_DEFAULT
	in_.sensitivity = music.PITCH_SENSITIVITY_DEFAULT
}

input_shutdown :: proc() {
	input_close()
	delete(g.input.take)
	g.input.take = nil
}

input_devices_refresh :: proc() {
	g.input.n_devices = mic_os_list(g.input.devices[:])
	g.input.listed = true
}

device_name :: proc(i: int) -> string {
	if i < 0 || i >= g.input.n_devices do return "System default"
	d := &g.input.devices[i]
	return d.len > 0 ? string(d.name[:d.len]) : fmt.tprintf("Device %d", i + 1)
}

@(private = "file")
input_open :: proc() -> bool {
	in_ := &g.input
	if in_.open do return true
	if err := mic_os_open(&in_.os, in_.device); err != "" {
		set_error("microphone: %s", err)
		return false
	}
	in_.open = true
	lo, hi := input_range()
	music.pitch_init(&in_.det, lo, hi)
	in_.det.sensitivity = in_.sensitivity
	in_.midi = 0
	return true
}

@(private = "file")
input_close :: proc() {
	if !g.input.open do return
	mic_os_close(&g.input.os)
	g.input.open = false
	g.input.midi = 0
}

input_toggle :: proc() {
	in_ := &g.input
	if in_.on {
		in_.on = false
		input_close()
		set_status("input off")
		return
	}
	if !in_.listed do input_devices_refresh()
	if !input_open() do return
	in_.on = true
	set_status("listening on %s - play a note (headphones help when playing along)", device_name(in_.device))
}

input_set_device :: proc(i: int) {
	g.input.device = i
	if g.input.on {
		input_close()
		if !input_open() do g.input.on = false
		else do set_status("listening on %s", device_name(i))
	}
}

input_reset :: proc() {
	clear(&g.input.take)
}

// The notes to listen for: the active layer's instrument's range.
@(private = "file")
input_range :: proc() -> (lo, hi: f32) {
	if t := active_track(); t != nil {
		ins := inst_of(t)
		return f32(ins.lo), f32(ins.hi)
	}
	return 28, 96
}

// Every frame: collect what the mic heard, find the notes in it, and while
// playing, add them to the take.
input_update :: proc() {
	in_ := &g.input
	if !in_.on || !in_.open do return
	samples: [MIC_BUF * MIC_BUFS]f32
	n := mic_os_read(&in_.os, samples[:])
	lo, hi := input_range()
	music.pitch_set_range(&in_.det, lo, hi)
	in_.det.sensitivity = in_.sensitivity
	readings: [64]music.Pitch_Reading
	k := music.pitch_feed(&in_.det, samples[:n], readings[:])
	now := rl.GetTime()
	for r in readings[:k] {
		heard := now - f64(r.delay) / music.PITCH_RATE - f64(in_.latency_ms) / 1000
		input_heard(r.midi, heard)
	}
	// A reading that has not come for a while (a stalled device) is stale.
	if now - in_.heard_at > 0.3 do in_.midi = 0
}

// One reading: `midi` (0 = nothing) was sounding at time `heard` (the
// frame clock). Also what the screenshot tool feeds.
input_heard :: proc(midi: f32, heard: f64) {
	in_ := &g.input
	in_.midi = midi
	in_.heard_at = rl.GetTime()
	if !g.player.playing do return
	tick := player_tick_at(&g.player, &g.song, heard)
	if tick < f32(g.player.from_tick) do return
	if g.player.stop_tick > 0 && tick >= f32(g.player.stop_tick) do return
	append(&in_.take, Take_Point{tick, midi})
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

// The colour opposite the active layer's (its hue turned half way round),
// kept bright enough to see on the dark sheet.
input_colour :: proc() -> rl.Color {
	base := COL_ACCENT
	if t := active_track(); t != nil do base = track_color(t)
	hsv := rl.ColorToHSV(base)
	if hsv.y < 0.15 do return {255, 70, 190, 255} // grey has no opposite: magenta
	return rl.ColorFromHSV(math.mod(hsv.x + 180, 360), max(hsv.y, 0.6), max(hsv.z, 0.9))
}

// Where on the sheet a (fractional) note goes: its row, moved up or down by
// how sharp or flat it is (a quarter tone off is most of the way to the
// row's edge).
@(private = "file")
input_y :: proc(midi: f32) -> (y: f32, step: int, cents: int) {
	m := int(math.round(midi))
	p := music.pitch_from_midi(m, int(g.song.key))
	step = clamp(int(p.step), sheet_lo(), sheet_hi())
	cents = int(math.round((midi - f32(m)) * 100))
	y = row_center(step) - f32(cents) / 50 * row_h() * 0.45
	return
}

// The take and the live dot, over the notes.
input_sheet_draw :: proc() {
	in_ := &g.input
	col := input_colour()
	ps := f32(page_start())
	pe := ps + f32(page_ticks())
	left, right := f32(bars_x()), f32(bars_x() + bars_w())

	// The take: a line through the readings, broken where nothing was played
	// (or where readings are more than a sixteenth apart).
	gap := f32(music.TPQ) / 4
	prev: Take_Point
	have := false
	for p in in_.take {
		if p.tick < ps - gap || p.tick > pe + gap {have = false; continue}
		if p.midi <= 0 {have = false; continue}
		if have && p.tick - prev.tick <= gap && p.tick >= prev.tick {
			x0 := clamp(left + (prev.tick - ps) * px_per_tick(), left, right)
			x1 := clamp(left + (p.tick - ps) * px_per_tick(), left, right)
			y0, _, _ := input_y(prev.midi)
			y1, _, _ := input_y(p.midi)
			same := int(math.round(prev.midi)) == int(math.round(p.midi))
			rl.DrawLineEx({x0, y0}, {x1, y1}, same ? 4 : 1.5, same ? col : with_alpha(col, 150))
		}
		prev = p
		have = true
	}

	if !in_.on do return
	// The live dot.
	x := f32(-1)
	if g.player.playing {
		t := player_tick(&g.player, &g.song)
		if f32(t) >= ps && f32(t) < pe do x = tick_x(t)
	} else {
		c := play_from()
		if f32(c) >= ps && f32(c) < pe do x = tick_x(c)
	}
	if x < 0 || in_.midi <= 0 do return
	y, _, cents := input_y(in_.midi)
	r := clamp(row_h() * 0.75, 9, 14)
	rl.DrawCircleV({x, y}, r + 2, {0, 0, 0, 160})
	rl.DrawCircleV({x, y}, r, col)
	rl.DrawCircleLines(i32(x), i32(y), r + 2, rl.WHITE)
	s := fmt.tprintf("%s %s%d", midi_name(int(math.round(in_.midi))), cents >= 0 ? "+" : "", cents)
	lx := x + r + 6
	if lx + text_width(s) + 6 > right do lx = x - r - 10 - text_width(s)
	fill(rect(lx - 3, y - 7, text_width(s) + 6, 14), {0, 0, 0, 170})
	text(s, lx, y - 5, abs(cents) <= 10 ? COL_GOOD : (abs(cents) <= 25 ? COL_ACCENT : COL_BAD))
}

// ---------------------------------------------------------------------------
// The practice controls: under the sheet, right of the page boxes.
// ---------------------------------------------------------------------------

PRACTICE_W :: 256

practice_draw :: proc() {
	y := f32(STRIP_Y)
	h := f32(STRIP_H)
	x := f32(bars_x() + bars_w() - PRACTICE_W)
	if button(rect(x, y, 48, h), "Metro", g.metronome) do metronome_toggle()
	x += 52
	{
		r := rect(x, y, 44, h)
		if button(r, SCOPE_NAME[g.input.scope], g.input.scope != .Song) do scope_step(1)
		if ui_take_right(r) do scope_step(-1)
	}
	x += 48
	if button(rect(x, y, 36, h), "Mic", g.input.on) do input_toggle()
	x += 38
	// The level, with the gate's threshold marked.
	{
		r := rect(x, y + 3, 34, h - 6)
		fill(r, COL_SHEET)
		if g.input.on {
			d := &g.input.det
			lvl := level_frac(d.level)
			fill(rect(r.x, r.y, r.width * lvl, r.height), g.input.midi > 0 ? input_colour() : COL_DIM)
			thr := level_frac(max(d.floor * d.sensitivity, music.PITCH_ABS_MIN))
			rl.DrawLineEx({r.x + r.width * thr, r.y - 2}, {r.x + r.width * thr, r.y + r.height + 2}, 1, COL_TEXT)
		}
		outline(r, COL_EDGE)
	}
	x += 36
	if button(rect(x, y, 18, h), "v", g.overlay == .Mic) do g.overlay = .Mic
	x += 22
	if button(rect(x, y, 44, h), "Reset", false, len(g.input.take) > 0) {
		input_reset()
		set_status("take cleared")
	}
}

// Level 0..1 on a -60..0 dBFS scale.
level_frac :: proc(rms: f32) -> f32 {
	db := 20 * math.log10(max(rms, 1e-6))
	return clamp((db + 60) / 60, 0, 1)
}

scope_step :: proc(dir: int) {
	n := len(Play_Scope)
	g.input.scope = Play_Scope((int(g.input.scope) + dir + n) % n)
	switch g.input.scope {
	case .Song:
		set_status("Play plays the song")
	case .Bar:
		set_status("Play plays one bar, from the cursor (left/right arrows move it)")
	case .Page:
		set_status("Play plays to the end of the page")
	}
}

// The microphone overlay: which device, the level, the gate, the latency.
mic_overlay_draw :: proc() {
	in_ := &g.input
	if !in_.listed do input_devices_refresh()
	W :: f32(340)
	rows := in_.n_devices + 1
	H := 200 + f32(rows) * 22
	r := rect(f32(bars_x() + bars_w()) - W, f32(STRIP_Y) - H - 4, W, H)
	fill(r, COL_PANEL)
	outline(r, COL_ACCENT)
	x := r.x + 10
	y := r.y + 8
	text("Microphone", x, y, COL_TEXT, FONT_BIG)
	if button(rect(r.x + W - 70, y, 60, 18), "Refresh") do input_devices_refresh()
	y += 26
	when !MIC_SUPPORTED {
		text("Microphone input is Windows-only in this build.", x, y, COL_BAD)
		y += 16
	}
	for i in -1 ..< in_.n_devices {
		if button(rect(x, y, W - 20, 20), fit_text(device_name(i), W - 34), in_.device == i) do input_set_device(i)
		y += 22
	}
	y += 6

	// The level meter, big: the room's floor and the gate marked on it.
	d := &in_.det
	text("level", x, y + 3, COL_DIM)
	m := rect(x + 40, y, W - 60, 14)
	fill(m, COL_SHEET)
	if in_.on {
		fill(rect(m.x, m.y, m.width * level_frac(d.level), m.height), in_.midi > 0 ? input_colour() : COL_DIM)
		fl := level_frac(d.floor)
		rl.DrawLineEx({m.x + m.width * fl, m.y}, {m.x + m.width * fl, m.y + m.height}, 2, COL_FAINT)
		th := level_frac(max(d.floor * d.sensitivity, music.PITCH_ABS_MIN))
		rl.DrawLineEx({m.x + m.width * th, m.y - 3}, {m.x + m.width * th, m.y + m.height + 3}, 2, COL_TEXT)
	}
	outline(m, COL_EDGE)
	y += 18
	if in_.on {
		note := in_.midi > 0 ? fmt.tprintf("%s  %.1f Hz", midi_name(int(math.round(in_.midi))), music.midi_freq(in_.midi)) : "-"
		room := d.floor > 0 ? fmt.tprintf("%.0f dB", 20 * math.log10(d.floor)) : "-"
		text(fmt.tprintf("hearing: %s     room %s", note, room), x + 40, y, COL_TEXT)
	} else {
		text("off - press Mic (or I) to listen", x + 40, y, COL_DIM)
	}
	y += 20

	// The gate.
	text("ignore noise", x, y + 4, COL_DIM)
	in_.sensitivity = stepper(rect(x + 90, y, 110, 18), in_.sensitivity, 1, 10, 0.5, music.PITCH_SENSITIVITY_DEFAULT, fmt.tprintf("x%.1f  %.0f dB", in_.sensitivity, 20 * math.log10(in_.sensitivity)))
	text("above the room", x + 206, y + 4, COL_FAINT)
	y += 22
	text("latency", x, y + 4, COL_DIM)
	in_.latency_ms = stepper(rect(x + 90, y, 110, 18), in_.latency_ms, 0, 400, 5, MIC_LATENCY_DEFAULT, fmt.tprintf("%.0f ms", in_.latency_ms))
	text("moves the take earlier", x + 206, y + 4, COL_FAINT)
	y += 26
	text("The white mark is the gate: sound left of it is room noise.", x, y, COL_FAINT)
	y += 12
	text("Playing along? Use headphones - the mic hears speakers too.", x, y, COL_FAINT)
	y += 12
	text("Listens for the active layer's range. I: mic   K: metronome", x, y, COL_FAINT)
	if hovered(r) do ui_take_all()
}
