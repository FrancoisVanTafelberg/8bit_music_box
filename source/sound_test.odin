package app

/*
    The sound effect tester: the SFX button in the top bar (music box only).

    Every sound effect in sounds/ as a button - click one to hear it (with a
    little random pitch, as a game would play it). Below, "many at once":
    fire N of the selected sound over a stretch of seconds, bunched along a
    bell curve - a shot or two alone at first, most of them together in the
    middle, stragglers at the end - through music.mixer_play_sfx_burst, the
    same call a game would make. The histogram shows when each shot fell, with
    the playhead moving across it.
*/

import "core:fmt"
import "music"
import rl "vendor:raylib"

SOUND_TEST_MAX :: 400

Sound_Test :: struct {
	selected: int,
	count:    int,
	seconds:  f32,
	volume:   f32,
	spread:   bool, // across the stereo field, or all in the middle
	// The last burst, for the histogram.
	times:    [SOUND_TEST_MAX]f32,
	n:        int,
	span:     f32,
	at:       f64,
	handle:   music.Sfx_Handle,
}

sound_test_draw :: proc() {
	st := &g.sfx_test
	r := rect(panel_w() + 20, TOP_H + 20, 1280 - panel_w() - 40, 600)
	fill(rect(0, 0, 1280, 720), {0, 0, 0, 150})
	fill(r, COL_PANEL)
	outline(r, COL_ACCENT)
	text("Sound effects", r.x + 12, r.y + 10, COL_TEXT, FONT_BIG)
	text("From the .sfx files in sounds/ (F7 reloads them). Click one to hear it. Esc closes.", r.x + 12, r.y + 34, COL_DIM)

	list := g.audio.sounds.list[:]
	if len(list) == 0 {
		text("No sound effects loaded - is there a sounds/ folder with .sfx files?", r.x + 12, r.y + 70, COL_BAD)
		if hovered(r) do ui_take_all()
		return
	}
	st.selected = clamp(st.selected, 0, len(list) - 1)

	// The effects.
	cols := 4
	bw := (r.width - 24 - f32(cols - 1) * 8) / f32(cols)
	for fx, i in list {
		br := rect(r.x + 12 + f32(i % cols) * (bw + 8), r.y + 58 + f32(i / cols) * 26, bw, 22)
		if button(br, fmt.tprintf("%s  (%s)", fx.name, fx.key), i == st.selected) {
			st.selected = i
			music.mixer_play_sfx(&g.audio, fx.key, vary = 0.7)
		}
	}
	y := r.y + 58 + f32((len(list) + cols - 1) / cols) * 26 + 16

	// Many at once.
	fx := &list[st.selected]
	rl.DrawLine(i32(r.x + 12), i32(y), i32(r.x + r.width - 12), i32(y), COL_EDGE)
	y += 10
	text(fmt.tprintf("Many at once: %s", fx.name), r.x + 12, y, COL_TEXT, FONT_BIG)
	y += 30
	// A burst can hold at most this many shots of this effect (the mixer's
	// voice limit, shared by every voice of every shot).
	most := clamp(music.MAX_SFX_VOICES / max(len(fx.voices), 1), 1, SOUND_TEST_MAX)
	st.count = clamp(st.count, 1, most)

	x := r.x + 12
	label("shots", x, y + 5)
	x += 40
	st.count = int(stepper(rect(x, y, 80, 20), f32(st.count), 1, f32(most), 1, 100, fmt.tprintf("%d", st.count)))
	x += 94
	label("over", x, y + 5)
	x += 32
	st.seconds = stepper(rect(x, y, 90, 20), st.seconds, 0.1, 30, 0.1, 2, fmt.tprintf("%.1f s", st.seconds))
	x += 104
	label("volume", x, y + 5)
	x += 44
	st.volume = stepper(rect(x, y, 80, 20), st.volume, 0.01, 3, 0.01, 1, fmt.tprintf("%d%%", int(st.volume * 100 + 0.5)))
	x += 94
	if button(rect(x, y, 96, 20), st.spread ? "spread L-R" : "all centre", st.spread) do st.spread = !st.spread
	x += 110
	if button(rect(x, y, 110, 20), "Play burst", true) {
		music.mixer_stop_sfx(&g.audio, st.handle)
		st.n = st.count
		st.span = st.seconds
		st.handle = music.mixer_play_sfx_burst(&g.audio, fx.key, st.count, st.seconds, st.volume, st.spread ? 0.8 : 0, 1, st.times[:st.n])
		st.at = rl.GetTime()
		set_status("%d x %s over %.2f s", st.count, fx.name, st.seconds)
	}
	x += 118
	if button(rect(x, y, 56, 20), "Stop") do music.mixer_stop_all_sfx(&g.audio, 0.05)
	y += 26
	text(fmt.tprintf("-/+: click 1, Shift+click 10, Ctrl+click 100 (seconds in tenths, volume in %%); wheel too, right-click resets. At most %d shots of this one (%d voices each).", most, len(fx.voices)), r.x + 12, y, COL_FAINT)
	y += 22

	// When each shot of the last burst fell.
	hr := rect(r.x + 12, y, r.width - 24, r.y + r.height - y - 30)
	fill(hr, COL_SHEET)
	outline(hr, COL_EDGE)
	if st.n > 0 {
		BINS :: 40
		counts: [BINS]int
		top := 1
		for t in st.times[:st.n] {
			b := clamp(int(t / st.span * BINS), 0, BINS - 1)
			counts[b] += 1
			top = max(top, counts[b])
		}
		bw2 := hr.width / BINS
		for c, b in counts {
			if c == 0 do continue
			h := (hr.height - 20) * f32(c) / f32(top)
			fill(rect(hr.x + f32(b) * bw2 + 1, hr.y + hr.height - h, bw2 - 2, h), COL_ACCENT)
		}
		// Where the sound is now (the output runs a block or two behind).
		elapsed := f32(rl.GetTime() - st.at - LATENCY)
		if elapsed >= 0 && elapsed <= st.span + 0.5 {
			px := hr.x + min(elapsed / st.span, 1) * hr.width
			rl.DrawLineEx({px, hr.y}, {px, hr.y + hr.height}, 2, COL_GOOD)
		}
		text(fmt.tprintf("%d shots over %.2f s, busiest %d in one %d ms slot", st.n, st.span, top, int(st.span * 1000 / BINS)), hr.x + 6, hr.y + 5, COL_DIM)
	} else {
		text("Play a burst to see when each shot falls.", hr.x + 6, hr.y + 5, COL_DIM)
	}
	text("0 s", hr.x, hr.y + hr.height + 4, COL_FAINT)
	end := fmt.tprintf("%.2f s", st.n > 0 ? st.span : st.seconds)
	text(end, hr.x + hr.width - text_width(end), hr.y + hr.height + 4, COL_FAINT)

	if hovered(r) do ui_take_all()
}
