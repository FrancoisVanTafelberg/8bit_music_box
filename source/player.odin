package app

/*
    Playback, through the same Mixer a game would use (music/mixer.odin).

    The Mixer renders blocks; music_rl.Output feeds them to a raylib
    AudioStream from the main loop. No audio callback: a callback runs on the
    audio thread, and a hot reload that unloads the code it points at crashes
    the app. Polling from the frame is safe, and at 120 fps with 2048-frame
    blocks (46 ms) the stream never runs dry unless the window is being dragged.

    The stream runs all the time (silence when nothing plays), so Play starts a
    song in the mixer, and a note preview is a one-note sound effect mixed over
    whatever is playing.

    WHERE IS THE PLAYHEAD? The clock, not the samples: time since Play, minus
    the stream's latency. Counting samples submitted would move the playhead in
    46 ms jumps; the clock moves it every frame, and is re-anchored if it ever
    drifts from the samples by more than a block.
*/

import "music"
import music_rl "music_rl"
import rl "vendor:raylib"

BLOCK :: 2048
LATENCY :: f64(BLOCK) / music.SAMPLE_RATE

Player :: struct {
	song:       music.Song_Handle,
	playing:    bool,
	from_tick:  i32,
	start_time: f64,
	base_sent:  int, // the stream's frame count when Play was pressed
	end_sent:   int, // ...when the song ended in the mixer; 0 while it plays
	preview:    music.Sfx_Handle,
}

player_init :: proc(p: ^Player) {
	if !rl.IsAudioDeviceReady() || !music_rl.output_open(&g.out, BLOCK) {
		set_error("no audio device - playback is off, export still works")
	}
}

player_destroy :: proc(p: ^Player) {
	player_stop(p)
	music_rl.output_close(&g.out)
}

player_play :: proc(p: ^Player, song: ^music.Song, from_tick: i32) {
	if !g.out.open do return
	player_stop(p)
	g.audio.mode = g.mode
	p.song = music.mixer_play_song(&g.audio, song, loop = false, from_tick = from_tick)
	p.from_tick = from_tick
	p.base_sent = g.out.sent
	p.end_sent = 0
	p.playing = true
	// Hand the first block over now, so the song is not a frame late.
	music_rl.output_update(&g.out, &g.audio)
	p.start_time = rl.GetTime()
}

player_stop :: proc(p: ^Player) {
	if p.song != 0 do music.mixer_stop_song(&g.audio, p.song)
	p.song = 0
	p.playing = false
}

player_update :: proc(p: ^Player, song: ^music.Song) {
	if p.playing {
		// Mute, solo and volume are live: whatever the layer panel says now
		// is what the next block plays.
		music.mixer_sync_song(&g.audio, p.song, song)
	}
	music_rl.output_update(&g.out, &g.audio)
	if !p.playing do return

	sent := g.out.sent - p.base_sent
	if p.end_sent == 0 && !music.mixer_song_playing(&g.audio, p.song) do p.end_sent = max(sent, 1)

	// Re-anchor the clock if it has wandered from the audio (a stalled frame,
	// a dragged window).
	heard := f64(sent) / music.SAMPLE_RATE - 2 * LATENCY
	now := rl.GetTime() - p.start_time
	if abs(now - heard) > 3 * LATENCY do p.start_time = rl.GetTime() - max(heard, 0)

	if p.end_sent > 0 && now > f64(p.end_sent) / music.SAMPLE_RATE {
		p.song = 0
		p.playing = false
	}
}

// The tick under the playhead right now.
player_tick :: proc(p: ^Player, song: ^music.Song) -> i32 {
	t := max(rl.GetTime() - p.start_time - LATENCY, 0)
	return p.from_tick + i32(t / music.tick_seconds(song))
}

// One note, now: what you hear when you place or click a note. The previous
// preview is cut short, so dragging a note up the staff does not pile up.
player_preview :: proc(p: ^Player, inst: music.Inst_Id, pitch: music.Pitch) {
	if !g.out.open do return
	music.mixer_stop_sfx(&g.audio, p.preview)
	g.audio.mode = g.mode
	p.preview = music.mixer_play_instrument(&g.audio, music.inst_get(&g.song, inst)^, f32(music.pitch_midi(pitch)), 0.35, 1.3)
}

toggle_play :: proc(from_start: bool) {
	if g.player.playing {
		player_stop(&g.player)
		return
	}
	from := from_start ? 0 : g.page * music.bar_ticks(&g.song) * BARS_PER_PAGE
	player_play(&g.player, &g.song, from)
}
