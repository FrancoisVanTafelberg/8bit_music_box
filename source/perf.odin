package app

/*
    FPS counter and performance monitor.

    The frame rate is always shown at the top right. F3 (or a click on it)
    opens the monitor: where each frame's time goes, split four ways -

      logic    input, files, the playhead, everything that is not the rest
      audio    mixing sound for the speakers (the synth: songs and effects)
      draw     drawing the sheet, panels and overlays into the canvas
      present  putting the canvas on screen - including waiting for the
               monitor's refresh, so a big number here is idle time, not work

    - as averages and worsts over the last two seconds, and as a graph of the
    last 240 frames (stacked in those colours, with lines at 120 and 60 fps).
    Below that, the audio side: how much of real time the mixing takes, how
    many voices are sounding, how far the mixing runs ahead of the speakers,
    and how many times the sound ran dry (underruns - heard as crackles).

    A debug build (the hot-reload one) is several times slower at mixing than
    a release build; the monitor says which one is running.
*/

import "core:fmt"
import "core:time"
import "music"
import rl "vendor:raylib"

PERF_N :: 240

Perf_Section :: enum {
	Logic,
	Audio,
	Draw,
	Present,
}

PERF_NAME := [Perf_Section]string {
	.Logic   = "logic",
	.Audio   = "audio mix",
	.Draw    = "draw",
	.Present = "present+vsync",
}

PERF_COL := [Perf_Section]rl.Color {
	.Logic   = {110, 160, 255, 255},
	.Audio   = {255, 150, 70, 255},
	.Draw    = {120, 220, 140, 255},
	.Present = {90, 94, 120, 255},
}

Perf_Frame :: struct {
	ms:        [Perf_Section]f32,
	mixed:     int, // audio frames mixed this frame
	mix_ms:    f32,
	underruns: int,
}

Perf :: struct {
	show: bool,
	hist: [PERF_N]Perf_Frame,
	at:   int, // next slot in hist
	cur:  Perf_Frame,
	mark: time.Tick,
}

perf_begin :: proc() {
	g.perf.cur = {}
	g.perf.mark = time.tick_now()
}

// Everything since the last mark goes to `s`.
perf_mark :: proc(s: Perf_Section) {
	now := time.tick_now()
	g.perf.cur.ms[s] += f32(time.duration_milliseconds(time.tick_diff(g.perf.mark, now)))
	g.perf.mark = now
}

perf_end :: proc() {
	g.perf.cur.mixed = g.out.stats.rendered
	g.perf.cur.mix_ms = f32(g.out.stats.render_ms)
	g.perf.cur.underruns = g.out.stats.underruns
	g.perf.hist[g.perf.at] = g.perf.cur
	g.perf.at = (g.perf.at + 1) % PERF_N
}

// The frame rate, top right; F3 or a click opens the monitor.
perf_draw :: proc() {
	fps := rl.GetFPS()
	s := fmt.tprintf("%d fps", fps)
	r := rect(1280 - text_width(s) - 10, 11, text_width(s) + 6, 12)
	c := fps >= 100 ? COL_GOOD : (fps >= 50 ? COL_ACCENT : COL_BAD)
	text(s, r.x + 3, r.y + 1, g.perf.show ? COL_ACCENT : c)
	if ui_take_click(r) || rl.IsKeyPressed(.F3) do g.perf.show = !g.perf.show
	if g.perf.show do perf_panel()
}

@(private = "file")
perf_panel :: proc() {
	p := &g.perf
	W :: 380
	H :: 330
	r := rect(1280 - W - 8, TOP_H + 6, W, H)
	fill(r, {10, 11, 20, 235})
	outline(r, COL_ACCENT)
	x := r.x + 10
	y := r.y + 8

	// The last two seconds (or what there is).
	fps := max(int(rl.GetFPS()), 1)
	n := clamp(fps * 2, 1, PERF_N)
	avg, worst: [Perf_Section]f32
	frame_avg, frame_worst: f32
	mixed, underruns_then := 0, 0
	mix_ms: f32
	for k in 0 ..< n {
		f := p.hist[(p.at - 1 - k + PERF_N * 2) % PERF_N]
		total: f32
		for sec in Perf_Section {
			avg[sec] += f.ms[sec]
			worst[sec] = max(worst[sec], f.ms[sec])
			total += f.ms[sec]
		}
		frame_avg += total
		frame_worst = max(frame_worst, total)
		mixed += f.mixed
		mix_ms += f.mix_ms
		if k == n - 1 do underruns_then = f.underruns
	}
	for &a in avg do a /= f32(n)
	frame_avg /= f32(n)

	build := ODIN_DEBUG ? "debug build (mixing is several times slower)" : "release build"
	text("PERFORMANCE  (F3)", x, y, COL_ACCENT)
	text(build, x + 120, y, ODIN_DEBUG ? COL_BAD : COL_GOOD)
	y += 16
	text(fmt.tprintf("%d fps    frame %.1f ms average, %.1f worst  (last %d frames)", rl.GetFPS(), frame_avg, frame_worst, n), x, y, COL_TEXT)
	y += 18

	// The sections.
	text("", x, y)
	right :: proc(s: string, x_right, y: f32, c: rl.Color) {text(s, x_right - text_width(s), y, c)}
	right("average", x + 176, y, COL_DIM)
	right("worst", x + 240, y, COL_DIM)
	right("share", x + 290, y, COL_DIM)
	y += 13
	busiest := Perf_Section.Logic
	work_total := avg[.Logic] + avg[.Audio] + avg[.Draw]
	for sec in Perf_Section {
		fill(rect(x, y + 1, 8, 8), PERF_COL[sec])
		text(PERF_NAME[sec], x + 14, y, COL_TEXT)
		right(fmt.tprintf("%.2f ms", avg[sec]), x + 176, y, COL_TEXT)
		right(fmt.tprintf("%.2f ms", worst[sec]), x + 240, y, worst[sec] > 16.7 ? COL_BAD : COL_TEXT)
		if sec != .Present {
			right(fmt.tprintf("%.0f%%", 100 * avg[sec] / max(work_total, 0.001)), x + 290, y, COL_DIM)
			if avg[sec] > avg[busiest] do busiest = sec
		}
		y += 13
	}
	text(fmt.tprintf("most work: %s", PERF_NAME[busiest]), x, y, COL_ACCENT)
	y += 18

	// The audio.
	secs_mixed := f64(mixed) / music.SAMPLE_RATE
	load := secs_mixed > 0 ? f64(mix_ms) / (secs_mixed * 1000) : 0
	song_voices := 0
	for sl in g.audio.songs do if sl.handle != 0 do song_voices += len(sl.engine.voices)
	sounding, waiting := 0, 0
	for s in g.audio.sfx {
		if s.voice.ev.start <= g.audio.frame do sounding += 1
		else do waiting += 1
	}
	st := g.out.stats
	text(fmt.tprintf("mixing takes %.0f%% of real time  (%.1f ms per 10 ms of sound)", load * 100, load * 10), x, y, load > 0.5 ? COL_BAD : COL_TEXT)
	y += 13
	text(fmt.tprintf("voices: song %d, effects %d sounding + %d waiting to start", song_voices, sounding, waiting), x, y, COL_TEXT)
	y += 13
	text(fmt.tprintf("stream: block %d (%.0f ms), mixed ahead %d, mode %s", g.out.block, f64(g.out.block) * 1000 / music.SAMPLE_RATE, st.buffered, music.SOUND_MODE_NAME[g.audio.mode]), x, y, COL_TEXT)
	y += 13
	recent := st.underruns - underruns_then
	text(fmt.tprintf("underruns (sound ran dry): %d in all, %d just now", st.underruns, recent), x, y, recent > 0 ? COL_BAD : COL_TEXT)
	y += 18

	// The graph: the last PERF_N frames, stacked.
	gr := rect(x, y, W - 20, r.y + H - y - 10)
	fill(gr, COL_SHEET)
	scale := gr.height / 33.3 // px per ms: the top is 30 fps
	for k in 0 ..< PERF_N {
		f := p.hist[(p.at + k) % PERF_N]
		bx := gr.x + f32(k) * gr.width / PERF_N
		by := gr.y + gr.height
		for sec in Perf_Section {
			h := min(f.ms[sec] * scale, by - gr.y)
			if h <= 0 do continue
			fill(rect(bx, by - h, max(gr.width / PERF_N, 1), h), PERF_COL[sec])
			by -= h
		}
	}
	for ms, i in ([2]f32{1000.0 / 120, 1000.0 / 60}) {
		ly := gr.y + gr.height - ms * scale
		rl.DrawLineEx({gr.x, ly}, {gr.x + gr.width, ly}, 1, with_alpha(COL_TEXT, 90))
		text(i == 0 ? "120 fps" : "60 fps", gr.x + 3, ly - 10, COL_DIM)
	}
	outline(gr, COL_EDGE)
	// The panel is not a way through to the sheet underneath.
	if hovered(r) do ui_take_all()
}
