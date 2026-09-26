package music

/*
    The song: what is saved, what is drawn, what is played.

    Times are in TICKS (TPQ to a quarter note) from the start of the song, not
    per bar: a bar is a way of LOOKING at the time line, so changing 4/4 to 3/4
    re-flows the bars without moving a single note.

    A track is a layer: one instrument and its notes, kept sorted by start tick
    so playback and drawing can walk them in order.
*/

import "core:slice"
import "core:strings"

Note :: struct {
	tick:  i32,
	len:   i32,
	pitch: Pitch,
	vel:   u8, // 1..127
}

Track :: struct {
	name:   string,
	inst:   Inst_Id,
	notes:  [dynamic]Note,
	volume: f32,
	pan:    f32,
	mute:   bool,
	solo:   bool,
	// The layer's own colour on the sheet; alpha 0 = its instrument's.
	color:  [4]u8,
	// Made by the program, not written: the editor's metronome. Never saved,
	// never exported, heard even when another layer is soloed.
	metronome: bool,
}

Song :: struct {
	title:     string,
	tempo:     f32, // quarter notes per minute
	beats:     i32, // time signature, top
	beat_unit: i32, // time signature, bottom
	key:       i32, // sharps (+) / flats (-)
	bars:      i32,
	tracks:    [dynamic]Track,
	// Instruments defined in the song itself (`define_instrument` blocks).
	// Tracks reach them through ids at SONG_INST_BASE and above.
	defs:      [dynamic]Instrument,
}

DEFAULT_VELOCITY :: u8(100)

song_init :: proc(s: ^Song) {
	s.title = strings.clone("Untitled")
	s.tempo = 120
	s.beats = 4
	s.beat_unit = 4
	s.key = 0
	s.bars = 8
}

song_destroy :: proc(s: ^Song) {
	for &t in s.tracks do track_destroy(&t)
	delete(s.tracks)
	for d in s.defs {
		delete(d.key)
		delete(d.name)
	}
	delete(s.defs)
	delete(s.title)
	s^ = {}
}

track_destroy :: proc(t: ^Track) {
	delete(t.notes)
	delete(t.name)
	t^ = {}
}

song_set_title :: proc(s: ^Song, title: string) {
	delete(s.title)
	s.title = strings.clone(title)
}

bar_ticks :: proc(s: ^Song) -> i32 {
	return s.beats * (TPQ * 4 / max(s.beat_unit, 1))
}

beat_ticks :: proc(s: ^Song) -> i32 {
	return TPQ * 4 / max(s.beat_unit, 1)
}

// Seconds per tick at the song's tempo.
tick_seconds :: proc(s: ^Song) -> f64 {
	return 60.0 / (f64(max(s.tempo, 1)) * TPQ)
}

// Where the last note of any track ends (the metronome's clicks do not
// count: they fill the bars there are, and must not make more).
song_end_tick :: proc(s: ^Song) -> i32 {
	end: i32
	for t in s.tracks do if !t.metronome do for n in t.notes do end = max(end, n.tick + n.len)
	return end
}

// Make sure there are enough bars to show every note, rounded up to a whole
// page of `per_page` bars, and never fewer than `min_bars`.
song_fit_bars :: proc(s: ^Song, per_page: i32, min_bars: i32 = 4) {
	bt := bar_ticks(s)
	need := (song_end_tick(s) + bt - 1) / bt
	need = max(need, s.bars, min_bars)
	s.bars = (need + per_page - 1) / per_page * per_page
}

song_add_track :: proc {
	song_add_track_id,
	song_add_track_key,
}

// A new layer playing the instrument with this key (or the default one).
song_add_track_key :: proc(s: ^Song, key: string, name := "") -> int {
	return song_add_track_id(s, inst_or_default(s, key), name)
}

song_add_track_id :: proc(s: ^Song, inst: Inst_Id, name := "") -> int {
	ins := inst_get(s, inst)
	label := name
	if label == "" {
		// A second violin layer is "Violin 2", so the list can tell them apart.
		count := 1
		for t in s.tracks do if t.inst == inst do count += 1
		label = count == 1 ? ins.name : strings.concatenate({ins.name, " ", itoa_temp(count)}, context.temp_allocator)
	}
	append(&s.tracks, Track{name = strings.clone(label), inst = inst, volume = 0.8, pan = ins.pan})
	return len(s.tracks) - 1
}

// Copy an instrument into the song, so the song carries it. Every track that
// played `id` now plays the song's copy. Returns the copy's id.
song_embed_instrument :: proc(s: ^Song, id: Inst_Id) -> Inst_Id {
	if id >= SONG_INST_BASE do return id
	src := inst_get(s, id)^
	for d, i in s.defs do if d.key == src.key do return SONG_INST_BASE + Inst_Id(i)
	src.key = strings.clone(src.key)
	src.name = strings.clone(src.name)
	src.origin = .Song
	src.source = ""
	append(&s.defs, src)
	new_id := SONG_INST_BASE + Inst_Id(len(s.defs) - 1)
	for &t in s.tracks do if t.inst == id do t.inst = new_id
	return new_id
}

song_remove_track :: proc(s: ^Song, i: int) {
	if i < 0 || i >= len(s.tracks) do return
	track_destroy(&s.tracks[i])
	ordered_remove(&s.tracks, i)
}

// A layer by its name ("Bugle", "Fife 2"), or -1. For programs that play a
// song and want to mute one of its parts: engine_set_track_gain takes this.
song_track_index :: proc(s: ^Song, name: string) -> int {
	for t, i in s.tracks do if t.name == name do return i
	return -1
}

// Is anything soloed? Then only soloed tracks sound.
song_any_solo :: proc(s: ^Song) -> bool {
	for t in s.tracks do if t.solo do return true
	return false
}

track_audible :: proc(s: ^Song, t: ^Track) -> bool {
	if t.mute do return false
	if t.metronome do return true // solo a part and still keep time
	if song_any_solo(s) do return t.solo
	return true
}

// ---------------------------------------------------------------------------
// Editing a track
// ---------------------------------------------------------------------------

track_sort :: proc(t: ^Track) {
	slice.sort_by(t.notes[:], proc(a, b: Note) -> bool {
		if a.tick != b.tick do return a.tick < b.tick
		return pitch_midi(a.pitch) < pitch_midi(b.pitch)
	})
}

// Put a note in, replacing anything at the same SOUNDING pitch it overlaps -
// two violins cannot play the same string at once, and a replaced note is
// what the person clicking meant. Returns the new note's index.
track_put :: proc(t: ^Track, n: Note) -> int {
	m := pitch_midi(n.pitch)
	for i := len(t.notes) - 1; i >= 0; i -= 1 {
		o := t.notes[i]
		if pitch_midi(o.pitch) != m do continue
		if o.tick < n.tick + n.len && n.tick < o.tick + o.len {
			ordered_remove(&t.notes, i)
		}
	}
	append(&t.notes, n)
	track_sort(t)
	return track_find_exact(t, n)
}

track_find_exact :: proc(t: ^Track, n: Note) -> int {
	for o, i in t.notes do if o == n do return i
	return -1
}

// The note on this staff step that covers this tick, if any. The last one
// wins, because it is drawn on top.
track_note_at :: proc(t: ^Track, step: int, tick: i32) -> int {
	for i := len(t.notes) - 1; i >= 0; i -= 1 {
		o := t.notes[i]
		if int(o.pitch.step) == step && o.tick <= tick && tick < o.tick + o.len do return i
	}
	return -1
}

@(private)
itoa_temp :: proc(n: int) -> string {
	buf := make([]u8, 12, context.temp_allocator)
	i := len(buf)
	v := n
	if v == 0 {
		i -= 1
		buf[i] = '0'
	}
	for v > 0 {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
	}
	return string(buf[i:])
}
