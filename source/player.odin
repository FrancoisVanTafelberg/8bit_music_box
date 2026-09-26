package app

/*
    Playback, through the same Mixer a game would use (music/mixer.odin).

    The Mixer renders blocks; music_rl.Output feeds them to a raylib
    AudioStream from the main loop. No audio callback: a callback runs on the
    audio thread, and a hot reload that unloads the code it points at crashes
    the app. Polling from the frame is safe: music_rl mixes a little every
    frame, a block (1024 frames, 23 ms) ahead of the stream, which holds two
    more - about 70 ms in all, so it only runs dry if a frame stalls longer
    than that (a window being dragged). F3 shows how it is keeping up.

    The stream runs all the time (silence when nothing plays), so Play starts a
    song in the mixer, and a note preview is a one-note sound effect mixed over
    whatever is playing.

    WHERE IS THE PLAYHEAD? The clock, not the samples: time since Play, minus
    the stream's latency. Counting samples submitted would move the playhead in
    46 ms jumps; the clock moves it every frame, and is re-anchored if it ever
    drifts from the samples by more than a block.
*/

import "core:math"
import "music"
import music_rl "music_rl"
import rl "vendor:raylib"

BLOCK :: 1024
LATENCY :: f64(BLOCK) / music.SAMPLE_RATE

Player :: struct {
	song:       music.Song_Handle,
	playing:    bool,
	from_tick:  i32,
	start_time: f64,
	base_sent:  int, // the mixer's frame count when Play was pressed
	end_sent:   int, // ...when the song ended in the mixer; 0 while it plays
	stop_tick:  i32, // the Bar and Page play scopes stop here; 0 = the song's end
	preview:    music.Sfx_Handle,
	// Repeat: the engine goes round from_tick .. from_tick + loop_ticks
	// (the scope's end, or the end of the song's last bar), and so does the
	// playhead. `pass` counts the times round; `last_pass`, once Repeat has
	// been switched off mid-play, is the pass to finish on (-1: none).
	loop:       bool,
	loop_ticks: i32,
	pass:       int,
	last_pass:  int,
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
	p.stop_tick = scope_end(from_tick)
	p.loop_ticks = loop_length(song, from_tick, p.stop_tick)
	p.loop = g.repeat && p.loop_ticks > 0
	p.pass = 0
	p.last_pass = -1
	p.song = music.mixer_play_song(&g.audio, song, loop = p.loop, from_tick = from_tick, to_tick = p.stop_tick > 0 ? p.stop_tick : -1)
	p.from_tick = from_tick
	// Where in the stream the song begins: after everything mixed so far,
	// including what is mixed ahead and not yet handed over.
	p.base_sent = g.audio.frame
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

	sent := g.out.sent - p.base_sent // negative until the mixed-ahead part is handed over
	if p.end_sent == 0 && !music.mixer_song_playing(&g.audio, p.song) do p.end_sent = max(g.audio.frame - p.base_sent, 1)

	// Re-anchor the clock if it has wandered from the audio (a stalled frame,
	// a dragged window).
	heard := f64(sent) / music.SAMPLE_RATE - 2 * LATENCY
	now := rl.GetTime() - p.start_time
	if abs(now - heard) > 3 * LATENCY do p.start_time = rl.GetTime() - max(heard, 0)

	// Going round: a new pass starts the take (and the checks) afresh.
	if p.loop || p.last_pass >= 0 {
		pass := player_pass(p, song)
		if p.last_pass >= 0 && pass > p.last_pass {
			// Repeat was switched off: this pass was the last.
			player_stop(p)
			input_pass_end()
			return
		}
		if pass != p.pass {
			p.pass = pass
			input_pass_end()
		}
		return
	}
	if p.stop_tick > 0 {
		// A scope ends at its bar line, not where the last note stops.
		if player_tick(p, song) >= p.stop_tick do player_stop(p)
	} else if p.end_sent > 0 && now > f64(p.end_sent) / music.SAMPLE_RATE {
		p.song = 0
		p.playing = false
	}
}

// How long one time round is, playing from `from`: to the scope's end, or
// to the end of the bar the song's last note ends in (as the engine does).
loop_length :: proc(song: ^music.Song, from, stop: i32) -> i32 {
	bt := music.bar_ticks(song)
	end := (music.song_end_tick(song) + bt - 1) / bt * bt
	if stop > 0 do end = stop
	return max(end - from, 0)
}

// Which time round the playhead is on (0 the first) - now, or at `time`.
player_pass :: proc(p: ^Player, song: ^music.Song) -> int {
	return player_pass_at(p, song, rl.GetTime())
}

player_pass_at :: proc(p: ^Player, song: ^music.Song, time: f64) -> int {
	if p.loop_ticks <= 0 do return 0
	t := max(time - p.start_time - LATENCY, 0) / music.tick_seconds(song)
	return int(t / f64(p.loop_ticks))
}

// The Repeat button (and R): go round again at the end instead of stopping.
// Switched on while playing, the engine is told at once; switched off, the
// time round being played is the last.
repeat_toggle :: proc() {
	g.repeat = !g.repeat
	p := &g.player
	if p.playing {
		if g.repeat {
			if p.loop_ticks > 0 {
				music.mixer_set_song_loop(&g.audio, p.song, true)
				p.loop = true
				p.last_pass = -1
				p.pass = player_pass(p, &g.song)
			}
		} else if p.loop {
			music.mixer_set_song_loop(&g.audio, p.song, false)
			p.loop = false
			p.last_pass = player_pass(p, &g.song)
		}
	}
	set_status(g.repeat ? "repeat on: at the end, back to where Play started, and round again" : "repeat off")
}

// Where the play scope (input.odin) ends, playing from `from`: the end of
// its bar, or of its page; 0 for the whole song.
scope_end :: proc(from: i32) -> i32 {
	bt := music.bar_ticks(&g.song)
	switch g.input.scope {
	case .Song, .Scroll:
		return 0
	case .Bar:
		return (from / bt + 1) * bt
	case .Page:
		per := bt * BARS_PER_PAGE
		return (from / per + 1) * per
	}
	return 0
}

// The tick under the playhead right now.
player_tick :: proc(p: ^Player, song: ^music.Song) -> i32 {
	return i32(player_tick_at(p, song, rl.GetTime()))
}

// The (fractional) tick that was being heard at `time` (the frame clock).
// Repeating, it goes round with the engine.
player_tick_at :: proc(p: ^Player, song: ^music.Song, time: f64) -> f32 {
	t := max(time - p.start_time - LATENCY, 0) / music.tick_seconds(song)
	if (p.loop || p.last_pass >= 0) && p.loop_ticks > 0 do t = math.mod(t, f64(p.loop_ticks))
	return f32(p.from_tick) + f32(t)
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
	// A new take: what was drawn last time goes.
	input_reset()
	player_play(&g.player, &g.song, from_start ? 0 : play_from())
}

// Where Play starts: the bar cursor (set by the left and right arrows) if it
// is on the page being shown, otherwise the start of that page.
play_from :: proc() -> i32 {
	ps := g.page * music.bar_ticks(&g.song) * BARS_PER_PAGE
	pe := ps + music.bar_ticks(&g.song) * BARS_PER_PAGE
	if g.cursor_tick >= ps && g.cursor_tick < pe do return g.cursor_tick
	return ps
}

// Left and right arrows: -1 goes back to the start of the bar we are in -
// or, already at its start, to the bar before; +1 to the start of the next
// bar. While playing, playback jumps there; stopped, the bar cursor moves
// (Play starts from it). The page follows.
bar_step :: proc(dir: int) {
	bt := music.bar_ticks(&g.song)
	pos := g.player.playing ? player_tick(&g.player, &g.song) : play_from()
	start := pos / bt * bt
	target := start + bt
	if dir < 0 {
		// "Already at the start": while playing, within half a beat of it.
		near := g.player.playing ? music.beat_ticks(&g.song) / 2 : 0
		target = pos - start <= near ? start - bt : start
	}
	last := max(music.song_end_tick(&g.song) / bt, g.song.bars - 1)
	target = clamp(target, 0, last * bt)
	g.cursor_tick = target
	g.page = clamp(target / (bt * BARS_PER_PAGE), 0, page_count() - 1)
	if g.player.playing do player_play(&g.player, &g.song, target)
}

// Up and down arrows: the overall volume, 5% a press (Shift: 20%).
volume_step :: proc(steps: int) {
	v := clamp(f32(int(g.audio.master * 20 + 0.5) + steps) / 20, 0, 2)
	g.audio.master = v
	set_status("volume %d%%", int(v * 100 + 0.5))
}
