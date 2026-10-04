package app

/*
    The sound effect tester: the SFX button in the top bar (music box only).

    Every sound effect in sounds/ as a button - click one to hear it (with a
    little random pitch, as a game would play it). A group of variations
    (`group musket` in the .sfx files: the musket shots) is one button, with
    < > either side to step through them, each played as it comes up. Below, "many at once":
    fire N of the selected sound over a stretch of seconds, bunched along a
    bell curve - a shot or two alone at first, most of them together in the
    middle, stragglers at the end - through music.mixer_play_sfx_burst, the
    same call a game would make. The histogram shows when each shot fell, with
    the playhead moving across it. For a grouped sound, "all mixed" makes
    each shot a random one of the group (mixer_play_sfx_burst's `mixed`).

    Below it, the bus the sound plays on (music/bus.odin): its volume, an
    effect to try on it (muffled, thin, echo), its meter, and the master's
    limiter with how far it is turning the mix down.

    Where on the screen: the position slider, 0 % the left edge, 50 % the
    middle, 100 % the right edge. A balance, not a pan: in the middle both
    ears hear it at full; moving it left turns the right ear down (to nothing
    at the edge), never the left up - a cannon at 10 % is 100 % left, 20 %
    right. Clicks and bursts both play there (music.mixer_play_sfx_at /
    screen_pan, what a game would call with the cannon's x on its screen).
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
	spread:   bool, // across the stereo field, or all at one place
	mixed:    bool, // a burst of a grouped sound: every shot any of the group
	// Which member each group's button is showing, by the button's place
	// among the buttons (a group's buttons steps through them with < >).
	group_pick: [64]i32,
	position: f32, // where on the screen: 0 left edge .. 0.5 middle .. 1 right edge
	// The last burst, for the histogram.
	times:    [SOUND_TEST_MAX]f32,
	n:        int,
	span:     f32,
	at:       f64,
	handle:   music.Sfx_Handle,
}

sound_test_draw :: proc() {
	st := &g.sfx_test
	r := rect(panel_w() + 20, TOP_H + 20, screen_w() - panel_w() - 40, 600)
	fill(rect(0, 0, screen_w(), screen_h()), {0, 0, 0, 150})
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

	// The effects: one button each, or one for a whole group of variations
	// (the musket shots) with < > either side to step through them.
	cols := 4
	bw := (r.width - 24 - f32(cols - 1) * 8) / f32(cols)
	slot := 0
	for fx, i in list {
		if fx.group != "" && sfx_group_first(list, fx.group) != i do continue // shown on its group's button
		br := rect(r.x + 12 + f32(slot % cols) * (bw + 8), r.y + 58 + f32(slot / cols) * 26, bw, 22)
		if fx.group == "" {
			if button(br, fmt.tprintf("%s  (%s)", fx.name, fx.key), i == st.selected) {
				st.selected = i
				music.mixer_play_sfx_at(&g.audio, fx.key, st.position, vary = 0.7)
			}
		} else {
			// The member showing: the selected one if it is in this group,
			// else the one it showed last.
			pick := &st.group_pick[min(slot, len(st.group_pick) - 1)]
			if list[st.selected].group == fx.group do pick^ = i32(st.selected)
			if int(pick^) >= len(list) || list[pick^].group != fx.group do pick^ = i32(i)
			cur := int(pick^)
			in_group := list[st.selected].group == fx.group
			step := 0
			if button(rect(br.x, br.y, 20, br.height), "<", in_group) do step = -1
			if button(rect(br.x + br.width - 20, br.y, 20, br.height), ">", in_group) do step = 1
			mid := rect(br.x + 24, br.y, br.width - 48, br.height)
			n, at := sfx_group_place(list, cur)
			play := button(mid, fmt.tprintf("%s  (%s)", list[cur].name, list[cur].key), in_group)
			if step != 0 {
				cur = sfx_group_step(list, cur, step)
				pick^ = i32(cur)
				play = true
				n, at = sfx_group_place(list, cur)
			}
			if play {
				st.selected = cur
				music.mixer_play_sfx_at(&g.audio, list[cur].key, st.position, vary = 0.7)
				set_status("%s: %d of %d (< > for the others)", list[cur].name, at + 1, n)
			}
		}
		slot += 1
	}
	y := r.y + 58 + f32((slot + cols - 1) / cols) * 26 + 12

	// Where on the screen it happens.
	{
		x := r.x + 12
		label("position", x, y + 5)
		sr := rect(x + 60, y, 360, 20)
		// The screen, as the slider's backdrop: its edges and middle marked.
		fill(rect(sr.x - 6, sr.y - 2, sr.width + 12, sr.height + 4), COL_SHEET)
		for m in ([3]f32{0, 0.5, 1}) {
			mx := sr.x + m * sr.width
			rl.DrawLineEx({mx, sr.y - 2}, {mx, sr.y + sr.height + 2}, 1, COL_FAINT)
		}
		slider(sr, &st.position, 0, 1, 0.01, 0.5)
		text("left edge", sr.x - 6, sr.y + sr.height + 4, COL_FAINT)
		text("middle", sr.x + sr.width / 2 - text_width("middle") / 2, sr.y + sr.height + 4, COL_FAINT)
		text("right edge", sr.x + sr.width + 6 - text_width("right edge"), sr.y + sr.height + 4, COL_FAINT)
		// What each ear hears.
		p := st.position
		left, right := min(1, 2 * (1 - p)), min(1, 2 * p)
		tx := sr.x + sr.width + 20
		text(fmt.tprintf("%d%%", int(p * 100 + 0.5)), tx, y + 5, COL_TEXT)
		ear :: proc(name: string, v: f32, x, y: f32) {
			text(name, x, y + 5, COL_DIM)
			b := rect(x + 36, y + 4, 80, 12)
			fill(b, COL_SHEET)
			fill(rect(b.x, b.y, b.width * v, b.height), COL_GOOD)
			outline(b, COL_EDGE)
			text(fmt.tprintf("%d%%", int(v * 100 + 0.5)), b.x + b.width + 6, y + 5, COL_TEXT)
		}
		ear("left", left, tx + 44, y)
		ear("right", right, tx + 210, y)
		y += 40
	}

	// The bus the selected sound plays on (music/bus.odin): its volume, an
	// effect to try, its meter; and the master's limiter.
	{
		fxs := &list[st.selected]
		bus := music.BUS_SFX
		if fxs.bus != "" {
			if bb, ok := music.mixer_bus_create(&g.audio, fxs.bus); ok do bus = bb
		}
		x := r.x + 12
		label("bus", x, y + 5)
		text(music.bus_name(&g.audio, bus), x + 60, y + 5, COL_TEXT)
		x += 130
		v := music.mixer_bus_volume(&g.audio, bus)
		nv := stepper(rect(x, y, 90, 20), v, 0, 2, 0.05, 1, fmt.tprintf("%d%%", int(v * 100 + 0.5)))
		if nv != v do music.mixer_set_bus_volume(&g.audio, bus, nv)
		x += 100
		EFFECT_NAMES := [music.Effect_Kind]string{.None = "no effect", .Low_Pass = "muffled", .High_Pass = "thin", .Echo = "echo", .Custom = "custom"}
		kind := music.mixer_bus_effect(&g.audio, bus)
		if button(rect(x, y, 90, 20), EFFECT_NAMES[kind], kind != .None) {
			// Round the built-in effects: none, muffled, thin, echo.
			switch kind {
			case .None:
				music.mixer_set_bus_low_pass(&g.audio, bus, 700)
			case .Low_Pass:
				music.mixer_set_bus_high_pass(&g.audio, bus, 1200)
			case .High_Pass:
				music.mixer_set_bus_echo(&g.audio, bus, 0.32, 0.4, 0.4)
			case .Echo, .Custom:
				music.mixer_set_bus_low_pass(&g.audio, bus, 0)
			}
		}
		x += 100
		// Its meter: the last block's peak.
		mr := rect(x, y + 4, 80, 12)
		fill(mr, COL_SHEET)
		pk := clamp(music.mixer_bus_peak(&g.audio, bus) * music.MASTER, 0, 1)
		fill(rect(mr.x, mr.y, mr.width * pk, mr.height), COL_GOOD)
		outline(mr, COL_EDGE)
		x += 96
		lim := g.audio.limiter.on
		if button(rect(x, y, 90, 20), lim ? "limiter on" : "limiter off", lim) do music.mixer_set_limiter(&g.audio, !lim)
		x += 100
		red := music.mixer_limiter_reduction(&g.audio)
		text(lim ? fmt.tprintf("turning down %.1f dB", red) : "clipping at full scale", x, y + 5, red > 0.5 ? COL_ACCENT : COL_FAINT)
		y += 32
	}

	// Many at once.
	fx := &list[st.selected]
	rl.DrawLine(i32(r.x + 12), i32(y), i32(r.x + r.width - 12), i32(y), COL_EDGE)
	y += 10
	grouped := fx.group != ""
	mixed := grouped && st.mixed
	n_group, _ := sfx_group_place(list, st.selected)
	text(mixed ? fmt.tprintf("Many at once: all %d of the %s group, mixed", n_group, fx.group) : fmt.tprintf("Many at once: %s", fx.name), r.x + 12, y, COL_TEXT, FONT_BIG)
	y += 30
	// A burst can hold at most this many shots of this effect (the mixer's
	// voice limit, shared by every voice of every shot).
	voices := len(fx.voices)
	if mixed do for o in list do if o.group == fx.group do voices = max(voices, len(o.voices))
	most := clamp(music.MAX_SFX_VOICES / max(voices, 1), 1, SOUND_TEST_MAX)
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
	if button(rect(x, y, 96, 20), st.spread ? "spread out" : "all at one", st.spread) do st.spread = !st.spread
	x += 110
	if grouped {
		if button(rect(x, y, 110, 20), st.mixed ? "all mixed" : "this one only", st.mixed) do st.mixed = !st.mixed
		x += 118
	}
	if button(rect(x, y, 110, 20), "Play burst", true) {
		music.mixer_stop_sfx(&g.audio, st.handle)
		st.n = st.count
		st.span = st.seconds
		st.handle = music.mixer_play_sfx_burst(&g.audio, fx.key, st.count, st.seconds, st.volume, st.spread ? 0.8 : 0, 1, st.times[:st.n], music.screen_pan(st.position), mixed)
		st.at = rl.GetTime()
		set_status("%d x %s over %.2f s", st.count, fx.name, st.seconds)
	}
	x += 118
	if button(rect(x, y, 56, 20), "Stop") do music.mixer_stop_all_sfx(&g.audio, 0.05)
	y += 26
	text(fmt.tprintf("-/+: click 1, Shift+click 10, Ctrl+click 100 (seconds in tenths, volume in %%); wheel too, right-click resets. At most %d shots of this one (%d voices each).", most, voices), r.x + 12, y, COL_FAINT)
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

// Where the first of a group is in the list.
@(private = "file")
sfx_group_first :: proc(list: []music.Sfx, group: string) -> int {
	for s, i in list do if s.group == group do return i
	return -1
}

// How many are in list[i]'s group, and which of them it is (1 and 0 alone).
@(private = "file")
sfx_group_place :: proc(list: []music.Sfx, i: int) -> (n, at: int) {
	if list[i].group == "" do return 1, 0
	for s, k in list {
		if s.group != list[i].group do continue
		if k == i do at = n
		n += 1
	}
	return
}

// The next (dir 1) or previous (-1) member of list[i]'s group, round and round.
@(private = "file")
sfx_group_step :: proc(list: []music.Sfx, i, dir: int) -> int {
	k := i
	for _ in 0 ..< len(list) {
		k = (k + dir + len(list)) % len(list)
		if list[k].group == list[i].group do return k
	}
	return i
}
