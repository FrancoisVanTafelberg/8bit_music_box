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
    at. Polling once a frame is safe. The stream holds two blocks, so a sound
    started now is heard within two blocks: `block` 1024 frames = 23 ms each at
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
}

// Start the stream. The audio device must be initialised (rl.InitAudioDevice);
// returns false if it is not.
output_open :: proc(o: ^Output, block := 1024) -> bool {
	output_close(o)
	if !rl.IsAudioDeviceReady() do return false
	o.block = max(block, 64)
	rl.SetAudioStreamBufferSizeDefault(i32(o.block))
	o.stream = rl.LoadAudioStream(music.SAMPLE_RATE, 32, 2)
	resize(&o.buf, o.block * 2)
	o.open = true
	o.sent = 0
	rl.PlayAudioStream(o.stream)
	return true
}

// Top the stream up from the mixer. Call it every frame.
output_update :: proc(o: ^Output, m: ^music.Mixer) {
	if !o.open do return
	for _ in 0 ..< 2 {
		if !rl.IsAudioStreamProcessed(o.stream) do break
		music.mixer_render(m, o.buf[:])
		rl.UpdateAudioStream(o.stream, raw_data(o.buf), i32(o.block))
		o.sent += o.block
	}
}

output_close :: proc(o: ^Output) {
	if o.open {
		rl.StopAudioStream(o.stream)
		rl.UnloadAudioStream(o.stream)
	}
	delete(o.buf)
	o^ = {}
}

// How far behind the mixer the speaker is, in seconds: two blocks.
output_latency :: proc(o: ^Output) -> f64 {
	return 2 * f64(o.block) / music.SAMPLE_RATE
}
