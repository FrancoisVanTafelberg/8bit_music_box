package app

/*
    The metronome: always the top layer.

    Every song, however it was opened or made, has a Metronome layer at the
    top of the list (layer 0). It is not written by hand: with the metronome
    on (the Metro button under the sheet, or K), it holds one click a beat
    on every bar of the song - the first beat of each bar higher and louder -
    and they follow the song as it changes: another time signature, more
    bars, and the clicks are laid out again. Off, the layer is empty.

    Being a layer, it plays through the same engine as the song, in time with
    it to the sample, and its M button mutes it like any other. It is never
    saved (music/song_io.odin skips it), never exported, cannot be edited or
    removed, and keeps sounding when another layer is soloed.

    The click is the `metronome` instrument in instruments/percussion.inst.
*/

import "core:strings"
import "music"

METRONOME_KEY :: "metronome"
METRO_HIGH :: 96 // C7: the downbeat
METRO_LOW :: 91 // G6: the other beats

@(private = "file")
metronome_track :: proc() -> ^music.Track {
	if len(g.song.tracks) > 0 && g.song.tracks[0].metronome do return &g.song.tracks[0]
	return nil
}

// Make sure the song has its metronome layer, on top, and that it holds
// the clicks it should. Cheap when nothing has changed: every frame.
metronome_sync :: proc() {
	t := metronome_track()
	if t == nil {
		// Anything that thinks it is a metronome but is not on top: gone.
		for i := len(g.song.tracks) - 1; i >= 0; i -= 1 {
			if g.song.tracks[i].metronome do music.song_remove_track(&g.song, i)
		}
		inst := music.inst_or_default(&g.song, METRONOME_KEY)
		inject_at(&g.song.tracks, 0, music.Track{name = strings.clone("Metronome"), inst = inst, volume = 0.7, metronome = true})
		g.active += 1
		g.metro_sig = {}
		t = &g.song.tracks[0]
	}
	sig := [4]i32{g.song.beats, g.song.beat_unit, g.song.bars, g.metronome ? 1 : 0}
	if sig == g.metro_sig do return
	g.metro_sig = sig
	clear(&t.notes)
	if !g.metronome do return
	bt := music.bar_ticks(&g.song)
	beat := music.beat_ticks(&g.song)
	for bar in 0 ..< g.song.bars {
		for b in 0 ..< g.song.beats {
			down := b == 0
			append(&t.notes, music.Note {
				tick  = bar * bt + b * beat,
				len   = max(beat / 4, 3),
				pitch = music.pitch_from_midi(down ? METRO_HIGH : METRO_LOW, 0),
				vel   = down ? 120 : 85,
			})
		}
	}
}

metronome_toggle :: proc() {
	g.metronome = !g.metronome
	metronome_sync()
	// Playing: carry on from here with (or without) the clicks. The engine
	// took its copy of the notes at Play, so it starts again where it is.
	// Repeating, it goes back to where the time round began.
	if g.player.playing do player_play(&g.player, &g.song, g.player.loop ? g.player.from_tick : player_tick(&g.player, &g.song))
	set_status(g.metronome ? "metronome on: a click a beat, the first of each bar higher" : "metronome off")
}

// Is layer `i` the metronome?
is_metronome :: proc(i: int) -> bool {
	return i >= 0 && i < len(g.song.tracks) && g.song.tracks[i].metronome
}

// How many layers there are that are not the metronome.
real_layers :: proc() -> int {
	n := 0
	for t in g.song.tracks do if !t.metronome do n += 1
	return n
}
