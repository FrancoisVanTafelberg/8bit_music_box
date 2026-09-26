package app

/*
    Input mode: play along on a real instrument, and see what you played.

    Switch it on (the Mic button under the sheet, or I) and the microphone is
    listened to (mic_windows.odin); which notes are sounding - one, or a
    chord of two, three or more - is worked out as it comes in
    (music/chord.odin: band-pass, the room's noise learned and taken away,
    harmonic salience, one note at a time), and shown:

      * as a big dot on the sheet for each note, in the colour opposite the
        layer's, on the row of the note, a little above or below the row's
        middle when the note is sharp or flat (with the name and cents beside
        it). Stopped, they sit on the bar cursor; playing, they ride the
        playhead;
      * with the Helper on, on the fingerboard too, where the notes are played
        (chosen as the tracking mode would), slid along the string by how
        sharp or flat they are - or on the keyboard's keys;
      * and while the song plays, as lines drawn behind the playhead, one for
        each note: the take. It stays on the sheet until Play or Reset.

    Two modes (the button beside Mic):

      Notes   what is said above: whatever is being played.
      Check   the same, and while the song plays each note of the layer being
              practised is checked against what was heard while it sounded
              (music.chord_check, music.check_verdict): outlined green when it
              was played in tune, blue when nearly (out of tune, a semitone
              off, in another octave, or only for part of it), red when it
              was not played. A note is judged once the playhead has passed
              it; the outlines stay until Play or Reset.

    Play scope (the button beside Play in the top bar): the whole song, the
    page (the four bars on the sheet), or one bar from the cursor. Page and
    Bar stop at their end, and the cursor stays where it was, so Play again
    goes round the same bars - or Repeat (beside it) goes round by itself,
    each time round a fresh take (and in Check mode, a count of how it went).

    Where the take is drawn in time: each reading knows how long ago the
    sound it describes was heard (music.Chord_Reading.delay: about 100 ms
    for the cello's range, 50 ms higher up), and the
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

// Up to this many notes of each reading are kept in the take and shown.
INPUT_NOTES :: 4

Take_Point :: struct {
	tick:  f32, // where in the song (fractional ticks)
	notes: [INPUT_NOTES]f32,
	n:     u8, // 0 = nothing played
}

Input_Mode :: enum u8 {
	Notes, // show what is played
	Check, // ...and check it against the layer
}

// One note of the layer, checked (Check mode).
Check_Note :: struct {
	tick:    i32,
	len:     i32,
	midi:    i16,
	tally:   music.Check_Tally,
	verdict: music.Check_Verdict,
	final:   bool,
}

Input :: struct {
	on:          bool,
	device:      int, // -1 = the system's default
	devices:     [MIC_MAX_DEVICES]Mic_Device,
	n_devices:   int,
	listed:      bool,
	os:          Mic_Os,
	open:        bool,
	det:         music.Chord_Detector,
	latency_ms:  f32,
	sensitivity: f32,
	mode:        Input_Mode,
	// Chords (several notes at once), or one note: the most prominent, or
	// the note under it whose overtones those are (music.chord_single).
	chords:      bool,
	// Now: the notes being played (n 0 = none), and when last heard.
	notes:       [INPUT_NOTES]f32,
	n:           int,
	heard_at:    f64,
	// The fingerboard places they are shown at, kept from reading to
	// reading so the tracking mode can choose the next ones from them.
	fb_pos:      [INPUT_NOTES]Fb_Pos,
	fb_midis:    [INPUT_NOTES]int,
	fb_n:        int,
	// What was played along with the song, and (Check) how each note of the
	// layer went: until Play or Reset.
	take:        [dynamic]Take_Point,
	checks:      [dynamic]Check_Note,
	was_playing: bool,
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
	delete(g.input.checks)
	g.input.take = nil
	g.input.checks = nil
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
	music.chord_init(&in_.det, lo, hi)
	in_.det.sensitivity = in_.sensitivity
	in_.n = 0
	return true
}

@(private = "file")
input_close :: proc() {
	if !g.input.open do return
	mic_os_close(&g.input.os)
	g.input.open = false
	g.input.n = 0
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
	clear(&g.input.checks)
}

// One note, or chords (the button under Tracking on the fingerboard, the
// keyboard's column, the microphone settings).
input_chords_toggle :: proc() {
	g.input.chords = !g.input.chords
	set_status(g.input.chords ? "mic: chords - every note it can pick out (up to 4)" : "mic: single note - the note played, not its overtones")
}

input_mode_step :: proc() {
	g.input.mode = g.input.mode == .Notes ? .Check : .Notes
	switch g.input.mode {
	case .Notes:
		set_status("input: the notes you play are shown")
	case .Check:
		set_status("check: play along - each note turns green (right), blue (nearly) or red (missed) once it has passed")
	}
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
// playing, add them to the take (and check them).
input_update :: proc() {
	in_ := &g.input
	if !in_.on || !in_.open {
		in_.was_playing = g.player.playing
		return
	}
	samples: [MIC_BUF * MIC_BUFS]f32
	n := mic_os_read(&in_.os, samples[:])
	lo, hi := input_range()
	music.chord_set_range(&in_.det, lo, hi)
	in_.det.sensitivity = in_.sensitivity
	in_.det.single = !in_.chords
	readings: [32]music.Chord_Reading
	k := music.chord_feed(&in_.det, samples[:n], readings[:])
	now := rl.GetTime()
	for &r in readings[:k] {
		heard := now - f64(r.delay) / music.PITCH_RATE - f64(in_.latency_ms) / 1000
		input_heard(&r, heard)
	}
	// A reading that has not come for a while (a stalled device) is stale.
	if now - in_.heard_at > 0.3 do in_.n = 0
	check_update()
}

// One reading, of what was sounding at time `heard` (the frame clock). Also
// what the screenshot tool feeds.
input_heard :: proc(r: ^music.Chord_Reading, heard: f64) {
	in_ := &g.input
	in_.n = min(r.n, INPUT_NOTES)
	for i in 0 ..< in_.n do in_.notes[i] = r.notes[i]
	in_.heard_at = rl.GetTime()
	if !g.player.playing do return
	// Repeating: sound from the time round before (it reaches the mic a
	// moment late) belongs to that take, which has gone.
	if (g.player.loop || g.player.last_pass >= 0) && player_pass_at(&g.player, &g.song, heard) != g.player.pass do return
	tick := player_tick_at(&g.player, &g.song, heard)
	if tick < f32(g.player.from_tick) do return
	if g.player.stop_tick > 0 && tick >= f32(g.player.stop_tick) do return
	p := Take_Point{tick = tick, n = u8(in_.n)}
	for i in 0 ..< in_.n do p.notes[i] = in_.notes[i]
	append(&in_.take, p)
	if in_.mode == .Check do check_reading(r, tick)
}

// ---------------------------------------------------------------------------
// Check mode
// ---------------------------------------------------------------------------

// A reading heard at `tick`: every note of the layer sounding then (past its
// first moment - the attack - and before its last) gets its verdict on it.
@(private = "file")
check_reading :: proc(r: ^music.Chord_Reading, tick: f32) {
	t := active_track()
	if t == nil do return
	spt := f32(music.tick_seconds(&g.song))
	// Everything the layer has sounding now, for chord_check.
	expected: [16]int
	ne := 0
	for note in t.notes {
		if f32(note.tick) > tick do break
		if tick < f32(note.tick + note.len) && ne < len(expected) {expected[ne] = music.pitch_midi(note.pitch); ne += 1}
	}
	for note in t.notes {
		if f32(note.tick) > tick do break
		ln := f32(note.len)
		skip := min(0.1 / spt, ln * 0.35) // the attack
		tail := min(0.04 / spt, ln * 0.15) // ...and the release
		if tick < f32(note.tick) + skip || tick >= f32(note.tick) + ln - tail do continue
		m := music.pitch_midi(note.pitch)
		c := check_find(note.tick, m)
		if c == nil {
			append(&g.input.checks, Check_Note{tick = note.tick, len = note.len, midi = i16(m)})
			c = &g.input.checks[len(g.input.checks) - 1]
		}
		if c.final do continue
		f, cents := music.chord_check(r, m, expected[:ne])
		music.check_add(&c.tally, f, cents)
		c.verdict = music.check_verdict(c.tally)
	}
}

check_find :: proc(tick: i32, midi: int) -> ^Check_Note {
	for &c in g.input.checks do if c.tick == tick && int(c.midi) == midi do return &c
	return nil
}

// Notes the playhead (as heard) has passed are judged for good; when play
// stops, the rest are, and the status line says how it went.
check_update :: proc() {
	in_ := &g.input
	if in_.mode == .Check {
		if g.player.playing {
			heard := player_tick_at(&g.player, &g.song, rl.GetTime() - f64(in_.latency_ms) / 1000 - 0.12)
			for &c in in_.checks do if !c.final && f32(c.tick + c.len) <= heard do c.final = true
		} else if in_.was_playing {
			check_summary()
		}
	}
	in_.was_playing = g.player.playing
}

// Judge what is left, and say how it went.
@(private = "file")
check_summary :: proc() {
	right, near, missed := 0, 0, 0
	for &c in g.input.checks {
		c.final = true
		switch c.verdict {
		case .Correct:
			right += 1
		case .Almost:
			near += 1
		case .Missed:
			missed += 1
		case .None:
		}
	}
	if len(g.input.checks) > 0 do set_status("checked %d notes: %d right, %d nearly, %d missed", right + near + missed, right, near, missed)
}

// Repeat: a time round is over. Checking, say how it went; then the take and
// the checks start afresh for the next.
input_pass_end :: proc() {
	if g.input.mode == .Check && g.input.on do check_summary()
	input_reset()
}

// The outline a checked note gets on the sheet: green right, blue nearly, red
// missed; ok false if it has none (yet).
check_colour :: proc(tick: i32, midi: int) -> (col: rl.Color, final: bool, ok: bool) {
	if g.input.mode != .Check do return
	c := check_find(tick, midi)
	if c == nil do return
	switch c.verdict {
	case .Correct:
		col = COL_GOOD
	case .Almost:
		col = CHECK_BLUE
	case .Missed:
		col = COL_BAD
	case .None:
		return
	}
	return col, c.final, true
}

CHECK_BLUE :: rl.Color{80, 160, 255, 255}

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
	m := note_of(midi)
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

	// The take: a line for each note, from each reading to the next - to the
	// nearest note of the reading before (within a tone and a half), broken
	// where nothing was played or readings are more than a sixteenth apart.
	gap := f32(music.TPQ) / 4
	prev: Take_Point
	for &p in in_.take {
		if p.tick < ps - gap || p.tick > pe + gap {prev = {}; continue}
		if prev.n > 0 && p.tick - prev.tick <= gap && p.tick >= prev.tick {
			x0 := clamp(left + (prev.tick - ps) * px_per_tick(), left, right)
			x1 := clamp(left + (p.tick - ps) * px_per_tick(), left, right)
			for a in p.notes[:p.n] {
				from := f32(-1)
				best := f32(1.5)
				for b in prev.notes[:prev.n] do if abs(a - b) < best {best = abs(a - b); from = b}
				if from < 0 do continue
				y0, _, _ := input_y(from)
				y1, _, _ := input_y(a)
				same := int(math.round(from)) == int(math.round(a))
				rl.DrawLineEx({x0, y0}, {x1, y1}, same ? 4 : 1.5, same ? col : with_alpha(col, 150))
			}
		}
		prev = p
	}

	if !in_.on do return
	// The live dots.
	x := f32(-1)
	if g.player.playing {
		t := player_tick(&g.player, &g.song)
		if f32(t) >= ps && f32(t) < pe do x = tick_x(t)
	} else {
		c := play_from()
		if f32(c) >= ps && f32(c) < pe do x = tick_x(c)
	}
	if x < 0 || in_.n == 0 do return
	r := clamp(row_h() * 0.75, 9, 14)
	last_label := f32(-1000)
	for i := in_.n - 1; i >= 0; i -= 1 { // top down, for the labels
		midi := in_.notes[i]
		y, _, cents := input_y(midi)
		rl.DrawCircleV({x, y}, r + 2, {0, 0, 0, 160})
		rl.DrawCircleV({x, y}, r, col)
		rl.DrawCircleLines(i32(x), i32(y), r + 2, rl.WHITE)
		s := fmt.tprintf("%s %s%d", midi_name(note_of(midi)), cents >= 0 ? "+" : "", cents)
		ly := max(y, last_label + 14) // labels kept apart when notes are close
		last_label = ly
		lx := x + r + 6
		if lx + text_width(s) + 6 > right do lx = x - r - 10 - text_width(s)
		fill(rect(lx - 3, ly - 7, text_width(s) + 6, 14), {0, 0, 0, 170})
		text(s, lx, ly - 5, abs(cents) <= 10 ? COL_GOOD : (abs(cents) <= 25 ? COL_ACCENT : COL_BAD))
	}
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
	if button(rect(x, y, 36, h), "Mic", g.input.on) do input_toggle()
	x += 38
	if button(rect(x, y, 44, h), g.input.mode == .Check ? "Check" : "Notes", g.input.mode == .Check) do input_mode_step()
	x += 48
	// The level, with the gate's threshold marked.
	{
		r := rect(x, y + 3, 34, h - 6)
		fill(r, COL_SHEET)
		if g.input.on {
			d := &g.input.det
			lvl := level_frac(d.level)
			fill(rect(r.x, r.y, r.width * lvl, r.height), g.input.n > 0 ? input_colour() : COL_DIM)
			thr := level_frac(max(d.floor * d.sensitivity, music.PITCH_ABS_MIN))
			rl.DrawLineEx({r.x + r.width * thr, r.y - 2}, {r.x + r.width * thr, r.y + r.height + 2}, 1, COL_TEXT)
		}
		outline(r, COL_EDGE)
	}
	x += 36
	if button(rect(x, y, 18, h), "v", g.overlay == .Mic) do g.overlay = .Mic
	x += 22
	if button(rect(x, y, 44, h), "Reset", false, len(g.input.take) > 0 || len(g.input.checks) > 0) {
		input_reset()
		set_status("take cleared")
	}
}

// Level 0..1 on a -60..0 dBFS scale.
level_frac :: proc(rms: f32) -> f32 {
	db := 20 * math.log10(max(rms, 1e-6))
	return clamp((db + 60) / 60, 0, 1)
}

// Song -> Page -> Bar -> Song (right-click: back).
scope_step :: proc(dir: int) {
	order := [3]Play_Scope{.Song, .Page, .Bar}
	i := 0
	for s, k in order do if s == g.input.scope do i = k
	g.input.scope = order[(i + dir + 3) % 3]
	switch g.input.scope {
	case .Song:
		set_status("Play plays the whole song")
	case .Page:
		set_status("Play plays the four bars on this page (from the cursor, if it is on it)")
	case .Bar:
		set_status("Play plays one bar, from the cursor (left/right arrows move it)")
	}
}

// The microphone overlay: which device, the level, the gate, the latency.
mic_overlay_draw :: proc() {
	in_ := &g.input
	if !in_.listed do input_devices_refresh()
	W :: f32(340)
	rows := in_.n_devices + 1
	H := 234 + f32(rows) * 22
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
		fill(rect(m.x, m.y, m.width * level_frac(d.level), m.height), in_.n > 0 ? input_colour() : COL_DIM)
		fl := level_frac(d.floor)
		rl.DrawLineEx({m.x + m.width * fl, m.y}, {m.x + m.width * fl, m.y + m.height}, 2, COL_FAINT)
		th := level_frac(max(d.floor * d.sensitivity, music.PITCH_ABS_MIN))
		rl.DrawLineEx({m.x + m.width * th, m.y - 3}, {m.x + m.width * th, m.y + m.height + 3}, 2, COL_TEXT)
	}
	outline(m, COL_EDGE)
	y += 18
	if in_.on {
		note := input_names()
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
	text("hear", x, y + 4, COL_DIM)
	if button(rect(x + 90, y, 110, 18), in_.chords ? "Chords" : "Single note", in_.chords) do input_chords_toggle()
	text(in_.chords ? "up to 4 notes at once" : "the note, not its overtones", x + 206, y + 4, COL_FAINT)
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
	y += 12
	text("Notes / Check (beside Mic): show what you play, or check it.", x, y, COL_FAINT)
	if hovered(r) do ui_take_all()
}

// "D3 A3" - the notes heard now, or "-".
input_names :: proc() -> string {
	in_ := &g.input
	if in_.n == 0 do return "-"
	s := ""
	for f in in_.notes[:in_.n] {
		m := note_of(f)
		s = len(s) == 0 ? midi_name(m) : fmt.tprintf("%s %s", s, midi_name(m))
	}
	return s
}

// The MIDI note nearest a fractional one, kept to the MIDI range.
note_of :: proc(f: f32) -> int {
	return clamp(int(math.round(f)), 0, 127)
}
