package music_rl

/*
    The Mixer's sound, out through raylib: an always-running AudioStream fed
    from the game loop.

        import music "music"            // wherever you put the two packages
        import music_rl "music_rl"

        rl.InitAudioDevice()
        out: music_rl.Output
        music_rl.output_open(&out)
        for !rl.WindowShouldClose() {
            music_rl.output_update(&out, &mixer)    // once a frame
            ...
        }
        music_rl.output_close(&out)

    No audio callback: a callback runs on raylib's audio thread, the Mixer is
    not thread-safe, and a hot reload would unload the code the callback points
    at. Polling once a frame is safe, and the mixing is spread over the frames
    (see output_update). The stream holds two blocks, so a sound started now
    is heard within two blocks and a half: `block` 1024 frames = 23 ms each at
    44.1 kHz. Use 2048 if the game can stall for more than ~40 ms (a window
    being dragged) and the stream runs dry.
*/

import music "../music"
import rl "vendor:raylib"

Output :: struct {
	stream: rl.AudioStream,
	open:   bool,
	block:  int,
	// Frames handed to the stream so far: a clock for syncing pictures to
	// the sound (see the editor's player.odin).
	sent:   int,
	buf:    [dynamic]f32,
	// Mixed ahead, waiting for the stream (see output_update).
	fifo:   [dynamic]f32,
	fill:   int, // frames in fifo
	last_t: f64, // when output_update last ran
	stats:  Output_Stats,
}

// For a performance monitor. Times are in milliseconds.
Output_Stats :: struct {
	render_ms:     f64, // mixing, during the last output_update
	rendered:      int, // frames mixed during the last output_update
	total_ms:      f64, // mixing, since opening
	total_frames:  int, // frames mixed since opening
	underruns:     int, // times the stream had played everything it had
	buffered:      int, // frames mixed ahead, waiting
}

// Mixing happens in pieces this big, spread over the frames.
@(private)
CHUNK :: 128

// Start the stream. The audio device must be initialised (rl.InitAudioDevice);
// returns false if it is not.
output_open :: proc(o: ^Output, block := 1024) -> bool {
	output_close(o)
	if !rl.IsAudioDeviceReady() do return false
	o.block = max(block, 64)
	rl.SetAudioStreamBufferSizeDefault(i32(o.block))
	o.stream = rl.LoadAudioStream(music.SAMPLE_RATE, 32, 2)
	resize(&o.buf, o.block * 2)
	resize(&o.fifo, o.block * 2)
	o.open = true
	o.sent = 0
	rl.PlayAudioStream(o.stream)
	return true
}

// Keep the stream fed from the mixer. Call it every frame.
//
// The stream takes a whole block at a time (1024-2048 frames), and mixing a
// whole block the moment it asks would put all that work into one frame: a
// battle's worth of gunfire made every fifth frame late - lag you can see.
// So the mixing is spread out: every frame mixes a little ahead, in small
// pieces, about as much as a frame's worth of sound (a little more, to stay
// ahead), up to a block ahead of the stream. When the stream asks, the block
// is ready; only if the frames have been slow is the rest mixed then.
output_update :: proc(o: ^Output, m: ^music.Mixer) {
	if !o.open do return
	now := rl.GetTime()
	dt := o.last_t > 0 ? now - o.last_t : 0
	o.last_t = now
	o.stats.render_ms = 0
	o.stats.rendered = 0

	// Mix ahead: a little more than a frame's worth of sound, up to a block
	// ahead - so when the stream asks, its block is already mixed.
	ahead := o.block
	per_frame := clamp(int(dt * music.SAMPLE_RATE * 1.25), CHUNK, o.block)
	budget := per_frame
	for o.fill < ahead && budget > 0 {
		mix_chunk(o, m, min(CHUNK, ahead - o.fill))
		budget -= CHUNK
	}

	processed := 0
	for _ in 0 ..< 2 {
		if !rl.IsAudioStreamProcessed(o.stream) do break
		// Whatever is not mixed yet, mix now.
		for o.fill < o.block do mix_chunk(o, m, min(CHUNK, o.block - o.fill))
		copy(o.buf[:], o.fifo[:o.block * 2])
		rest := o.fill - o.block
		copy(o.fifo[:rest * 2], o.fifo[o.block * 2:o.fill * 2])
		o.fill = rest
		rl.UpdateAudioStream(o.stream, raw_data(o.buf), i32(o.block))
		o.sent += o.block
		processed += 1
	}
	// Both halves empty at once: the stream had run dry (a stall, or mixing
	// that could not keep up) and a gap was heard. The first second does not
	// count: the stream starts empty.
	if processed == 2 && o.sent > music.SAMPLE_RATE do o.stats.underruns += 1
	o.stats.buffered = o.fill
}

@(private)
mix_chunk :: proc(o: ^Output, m: ^music.Mixer, frames: int) {
	if frames <= 0 do return
	if len(o.fifo) < (o.fill + frames) * 2 do resize(&o.fifo, (o.fill + frames) * 2)
	t := rl.GetTime()
	music.mixer_render(m, o.fifo[o.fill * 2:(o.fill + frames) * 2])
	ms := (rl.GetTime() - t) * 1000
	o.fill += frames
	o.stats.render_ms += ms
	o.stats.rendered += frames
	o.stats.total_ms += ms
	o.stats.total_frames += frames
}

output_close :: proc(o: ^Output) {
	if o.open {
		rl.StopAudioStream(o.stream)
		rl.UnloadAudioStream(o.stream)
	}
	delete(o.buf)
	delete(o.fifo)
	o^ = {}
}

// How far behind the mixer the speaker is, in seconds: the stream's two
// blocks, plus what is mixed ahead waiting for it.
output_latency :: proc(o: ^Output) -> f64 {
	return f64(2 * o.block + o.fill) / music.SAMPLE_RATE
}
