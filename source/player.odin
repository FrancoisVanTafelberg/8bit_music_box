package app

/*
    Playback.

    The synth engine (music/synth.odin) renders one block at a time; this feeds
    those blocks to a raylib AudioStream from the main loop. No audio callback:
    a callback runs on the audio thread, and a hot reload that unloads the code
    it points at crashes the app. Polling from the frame is safe, and at 120 fps
    with 2048-frame blocks (46 ms) the stream never runs dry unless the window is
    being dragged.

    WHERE IS THE PLAYHEAD? The clock, not the samples: time since Play, minus
    the stream's latency. Counting samples submitted would move the playhead in
    46 ms jumps; the clock moves it every frame, and is re-anchored if it ever
    drifts from the samples by more than a block.
*/

import "music"
import rl "vendor:raylib"

BLOCK :: 2048
LATENCY :: f64(BLOCK) / music.SAMPLE_RATE

Player :: struct {
	stream:     rl.AudioStream,
	has_stream: bool,
	engine:     music.Engine,
	playing:    bool,
	from_tick:  i32,
	start_time: f64,
	sent:       int, // frames submitted
	finished:   bool, // engine has nothing more to say; draining
	block:      [BLOCK * 2]f32,
	preview:    rl.Sound,
	has_preview: bool,
}

player_init :: proc(p: ^Player) {
	if !rl.IsAudioDeviceReady() {
		set_error("no audio device - playback is off, export still works")
		return
	}
	rl.SetAudioStreamBufferSizeDefault(BLOCK)
	p.stream = rl.LoadAudioStream(music.SAMPLE_RATE, 32, 2)
	p.has_stream = true
}

player_destroy :: proc(p: ^Player) {
	player_stop(p)
	if p.has_stream do rl.UnloadAudioStream(p.stream)
	if p.has_preview do rl.UnloadSound(p.preview)
	music.engine_destroy(&p.engine)
	p.has_stream = false
	p.has_preview = false
}

player_play :: proc(p: ^Player, song: ^music.Song, from_tick: i32) {
	if !p.has_stream do return
	player_stop(p)
	music.engine_start(&p.engine, song, from_tick, g.crush)
	p.from_tick = from_tick
	p.sent = 0
	p.finished = false
	p.playing = true
	// Fill both halves of the stream before it starts, so the first thing
	// heard is the song and not a block of silence.
	player_feed(p)
	rl.PlayAudioStream(p.stream)
	p.start_time = rl.GetTime()
}

player_stop :: proc(p: ^Player) {
	if p.playing && p.has_stream do rl.StopAudioStream(p.stream)
	p.playing = false
}

player_update :: proc(p: ^Player, song: ^music.Song) {
	if !p.playing do return
	player_feed(p)

	// Re-anchor the clock if it has wandered from the audio (a stalled frame,
	// a dragged window).
	heard := f64(p.sent) / music.SAMPLE_RATE - 2 * LATENCY
	now := rl.GetTime() - p.start_time
	if abs(now - heard) > 3 * LATENCY do p.start_time = rl.GetTime() - max(heard, 0)

	if p.finished && now > f64(p.sent) / music.SAMPLE_RATE {
		player_stop(p)
	}
}

@(private = "file")
player_feed :: proc(p: ^Player) {
	for _ in 0 ..< 2 {
		if !rl.IsAudioStreamProcessed(p.stream) do break
		if p.finished {
			for &s in p.block do s = 0
		} else if !music.engine_render(&p.engine, p.block[:]) {
			p.finished = true
		}
		rl.UpdateAudioStream(p.stream, &p.block[0], BLOCK)
		p.sent += BLOCK
	}
}

// The tick under the playhead right now.
player_tick :: proc(p: ^Player, song: ^music.Song) -> i32 {
	t := max(rl.GetTime() - p.start_time - LATENCY, 0)
	return p.from_tick + i32(t / music.tick_seconds(song))
}

// One note, now: what you hear when you place or click a note.
player_preview :: proc(p: ^Player, inst: music.Inst_Id, pitch: music.Pitch) {
	if !p.has_stream do return
	if p.has_preview {
		rl.UnloadSound(p.preview)
		p.has_preview = false
	}
	samples := music.render_preview(music.inst_get(&g.song, inst)^, pitch)
	defer delete(samples)
	wave := rl.Wave {
		frameCount = u32(len(samples) / 2),
		sampleRate = music.SAMPLE_RATE,
		sampleSize = 32,
		channels   = 2,
		data       = raw_data(samples),
	}
	p.preview = rl.LoadSoundFromWave(wave)
	p.has_preview = true
	rl.PlaySound(p.preview)
}

toggle_play :: proc(from_start: bool) {
	if g.player.playing {
		player_stop(&g.player)
		return
	}
	from := from_start ? 0 : g.page * music.bar_ticks(&g.song) * BARS_PER_PAGE
	player_play(&g.player, &g.song, from)
}
