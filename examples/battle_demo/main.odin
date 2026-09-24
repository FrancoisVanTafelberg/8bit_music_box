package battle_demo

/*
    The music box as a sound engine inside another program: a small window that
    plays a march, turns its layers on and off, and fires battle sounds over it.
    Everything it does is what a game would do.

        odin run examples/battle_demo          (from the project folder)

    Space        play / stop the march (fades)
    1 - 5        a layer on / off
    T            every trumpet on / off (by instrument)
    Y            only Trumpet 2 (solo a layer)        A   all layers back on
    L            loop on / off
    C  V  M      cannon, distant cannon, musket
    B            musket volley
    S  D         sword clash, sword drawn
    E  W         ship's bell, splash
    Up / Down    music volume        Left / Right   sound effect volume

    To use it in your own program, copy source/music (the engine, no raylib)
    and, for a raylib program, source/music_rl (the audio output), plus the
    instruments/ and sounds/ folders and the songs you want.
*/

import "core:fmt"
import "core:os"
import music "../../source/music"
import music_rl "../../source/music_rl"
import rl "vendor:raylib"

SONG :: "songs/british_grenadiers_trumpet.song"

Key_Sfx :: struct {
	key: rl.KeyboardKey,
	sfx: string,
}

main :: proc() {
	// Run from the project folder or from build/.
	root := os.is_dir("instruments") ? "." : ".."

	rl.InitWindow(900, 520, "Music box engine: battle demo")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)
	rl.InitAudioDevice()
	defer rl.CloseAudioDevice()

	// 1. The mixer, with the orchestra and the sound effects.
	mixer: music.Mixer
	music.mixer_init(&mixer)
	defer music.mixer_destroy(&mixer)
	rep: music.Load_Report
	defer music.report_destroy(&rep)
	music.mixer_load_instruments(&mixer, fmt.tprintf("%s/instruments", root), &rep)
	music.mixer_load_sounds(&mixer, fmt.tprintf("%s/sounds", root), &rep)
	for e in rep.errors do fmt.eprintln(e)

	// 2. Its way out to the speakers.
	out: music_rl.Output
	if !music_rl.output_open(&out) do fmt.eprintln("no audio device")
	defer music_rl.output_close(&out)

	// 3. The march, fading in over two seconds, looping.
	song_path := fmt.tprintf("%s/%s", root, SONG)
	march := music.mixer_play_song_file(&mixer, song_path, loop = true, fade_in = 2)
	looping := true

	keys := [?]Key_Sfx {
		{.C, "cannon"},
		{.V, "cannon_distant"},
		{.M, "musket"},
		{.B, "musket_volley"},
		{.S, "sword_clash"},
		{.D, "sword_draw"},
		{.E, "ship_bell"},
		{.W, "splash"},
	}
	last := ""

	for !rl.WindowShouldClose() {
		// Songs.
		if rl.IsKeyPressed(.SPACE) {
			if music.mixer_song_playing(&mixer, march) {
				music.mixer_stop_song(&mixer, march, fade_out = 1.5)
			} else {
				march = music.mixer_play_song_file(&mixer, song_path, loop = looping, fade_in = 0.5)
			}
		}
		if rl.IsKeyPressed(.L) {
			looping = !looping
			music.mixer_set_song_loop(&mixer, march, looping)
		}
		// Layers: by number here; a game would use names, e.g.
		// music.mixer_set_layer(&mixer, march, "Trumpet 1", true).
		for i in 0 ..< 9 {
			if rl.IsKeyPressed(rl.KeyboardKey(int(rl.KeyboardKey.ONE) + i)) {
				name, _ := music.mixer_layer_name(&mixer, march, i)
				if name != "" do music.mixer_set_layer(&mixer, march, name, !music.mixer_layer_on(&mixer, march, name))
			}
		}
		// By instrument: every layer playing the trumpet at once.
		if rl.IsKeyPressed(.T) {
			music.mixer_set_instrument(&mixer, march, "trumpet", !music.mixer_instrument_on(&mixer, march, "trumpet"))
		}
		if rl.IsKeyPressed(.Y) do music.mixer_solo_layer(&mixer, march, "Trumpet 2")
		if rl.IsKeyPressed(.A) do music.mixer_set_all_layers(&mixer, march, true)
		// Sound effects: a little random pitch so repeats differ, panned a
		// little at random too.
		for k in keys {
			if rl.IsKeyPressed(k.key) {
				pan := f32(rl.GetRandomValue(-40, 40)) / 100
				music.mixer_play_sfx(&mixer, k.sfx, pan = pan, vary = 0.7)
				last = k.sfx
			}
		}
		// Volumes: plain fields.
		if rl.IsKeyDown(.UP) do mixer.music_volume = min(mixer.music_volume + 0.01, 1.5)
		if rl.IsKeyDown(.DOWN) do mixer.music_volume = max(mixer.music_volume - 0.01, 0)
		if rl.IsKeyDown(.RIGHT) do mixer.sfx_volume = min(mixer.sfx_volume + 0.01, 1.5)
		if rl.IsKeyDown(.LEFT) do mixer.sfx_volume = max(mixer.sfx_volume - 0.01, 0)

		// Once a frame: hand the output its next blocks.
		music_rl.output_update(&out, &mixer)

		rl.BeginDrawing()
		rl.ClearBackground({24, 26, 34, 255})
		y: i32 = 20
		line :: proc(y: ^i32, s: string, c := rl.Color{220, 220, 220, 255}) {
			rl.DrawText(fmt.ctprint(s), 24, y^, 20, c)
			y^ += 28
		}
		playing := music.mixer_song_playing(&mixer, march)
		t, _ := music.mixer_song_time(&mixer, march)
		line(&y, fmt.tprintf("%s   %s   %.1f s   loop %v", music.mixer_song_title(&mixer, march), playing ? "playing" : "stopped", t, looping))
		for i in 0 ..< music.mixer_layer_count(&mixer, march) {
			name, inst := music.mixer_layer_name(&mixer, march, i)
			on := music.mixer_layer_on(&mixer, march, name)
			line(&y, fmt.tprintf("  %d  %-12s (%s)  %s", i + 1, name, inst, on ? "on" : "off"), on ? rl.Color{140, 220, 140, 255} : rl.Color{150, 90, 90, 255})
		}
		y += 10
		line(&y, fmt.tprintf("music %.0f%%   effects %.0f%%   (arrow keys)", mixer.music_volume * 100, mixer.sfx_volume * 100))
		line(&y, "Space play/stop   1-6 layers   T trumpets   Y only Trumpet 2   A all   L loop")
		line(&y, "C cannon  V distant cannon  M musket  B volley  S sword clash  D sword drawn  E bell  W splash")
		if last != "" do line(&y, fmt.tprintf("last: %s", last), {240, 200, 120, 255})
		rl.EndDrawing()
		free_all(context.temp_allocator)
	}
}
