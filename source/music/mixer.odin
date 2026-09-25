package music

/*
    THE MIXER: the one thing another program needs.

    Everything the music box can make a sound with, behind one struct: songs
    (several at once, looping, fading in and out), their layers muted and
    unmuted by name while they play, and sound effects - a cannon, a sword
    clash - on top. It hands back finished blocks of stereo f32; the program
    sends those to whatever audio output it has. No raylib in here: the
    music_rl package is a ready-made output for raylib programs.

        m: music.Mixer
        music.mixer_init(&m)
        music.mixer_load_instruments(&m, "instruments")
        music.mixer_load_sounds(&m, "sounds")

        march := music.mixer_play_song_file(&m, "songs/british_grenadiers_trumpet.song", fade_in = 2)
        music.mixer_set_layer(&m, march, "Trumpet 1", false)     // one layer, by name
        music.mixer_set_instrument(&m, march, "trumpet", false)  // every trumpet layer
        music.mixer_play_sfx(&m, "cannon", vary = 1)
        music.mixer_stop_song(&m, march, fade_out = 3)

        // and, every time the audio output wants more:
        music.mixer_render(&m, block[:])                     // L R L R ..., 44100 Hz

    HANDLES. A playing song is a Song_Handle, a sound effect a Sfx_Handle. A
    handle outlives its sound safely: once the song has ended (or been
    stopped), calls with its handle do nothing and mixer_song_playing says
    false. 0 is never a valid handle.

    VOLUMES. Each song has its own volume (mixer_set_song_volume, which can
    fade), each layer can be on or off and has a gain, and on top of all of it
    `music_volume`, `sfx_volume` and `master` are plain fields to set: the
    options-menu sliders. Every change is ramped over one block, so nothing
    clicks.

    THREADS. Not thread-safe: call everything, mixer_render included, from one
    thread (the game loop, polling the output, as music_rl does), or guard the
    mixer with a mutex if your audio output calls back from its own thread.

    ONE MIXER PER PROGRAM. Songs find their instruments through the package's
    current registry, which mixer_init points at this mixer's. A program that
    hot-reloads this package calls mixer_bind(&m) afterwards.
*/

import "core:math"
import "core:strings"

MAX_SONGS :: 4 // playing at once: e.g. the music, and a fanfare over it
MAX_SFX_VOICES :: 640 // sound effect voices at once (a 100-shot volley of a 4-voice musket is 400); the oldest gives way

Song_Handle :: distinct u32
Sfx_Handle :: distinct u32

Mixer :: struct {
	reg:          Registry, // the orchestra
	sounds:       Sfx_Bank, // the sound effects
	songs:        [MAX_SONGS]Song_Slot,
	sfx:          [dynamic]Sfx_Live,
	// Levels, 0..1 (more than 1 is allowed, and louder). Set them directly.
	master:       f32,
	music_volume: f32,
	sfx_volume:   f32,
	// 4-bit .. 32-bit (synth.odin). Used by songs and sounds started after it
	// is changed.
	mode:         Sound_Mode,
	frame:        int, // frames rendered so far
	next_handle:  u32,
	rng:          u32,
	scratch:      [dynamic]f32,
}

Song_Slot :: struct {
	handle:     Song_Handle, // 0 = free
	engine:     Engine,
	song:       Song, // our own copy, when loaded from a file
	owns_song:  bool,
	title:      string,
	layers:     [dynamic]Mixer_Layer,
	level:      f32, // the song's volume now
	goal:       f32, // ...heading here
	step:       f32, // ...by this much a frame
	applied:    f32, // the gain the last block ended on
	stopping:   bool, // free the slot when `level` reaches 0
}

Mixer_Layer :: struct {
	name:  string,
	inst:  string, // the instrument's key
	base:  f32, // the layer's own volume, from the song
	on:    bool,
	gain:  f32, // set by the program, 1 = as written
}

Sfx_Live :: struct {
	voice:   Voice,
	handle:  Sfx_Handle,
	level:   f32,
	step:    f32, // > 0 while being stopped
	applied: f32,
}

// ---------------------------------------------------------------------------
// Setting up
// ---------------------------------------------------------------------------

mixer_init :: proc(m: ^Mixer) {
	mixer_destroy(m)
	m.master = 1
	m.music_volume = 1
	m.sfx_volume = 1
	m.mode = DEFAULT_MODE
	m.rng = 0x2545F491
	registry_bind(&m.reg)
}

// After a hot reload of this package: point it at this mixer's instruments
// again.
mixer_bind :: proc(m: ^Mixer) {
	registry_bind(&m.reg)
}

mixer_destroy :: proc(m: ^Mixer) {
	for &s in m.songs do if s.handle != 0 do slot_free(&s)
	delete(m.sfx)
	delete(m.scratch)
	sfx_bank_destroy(&m.sounds)
	registry_destroy(&m.reg)
	m^ = {}
}

// Load (or reload) the orchestra from the .inst files in `dir`. Returns how
// many instruments were read. Reloading keeps songs already playing as they
// were; sound effects keep theirs until mixer_load_sounds runs again.
mixer_load_instruments :: proc(m: ^Mixer, dir := INST_DIR, rep: ^Load_Report = nil) -> int {
	local: Load_Report
	r := rep != nil ? rep : &local
	defer if rep == nil do report_destroy(&local)
	n := registry_load_dir(&m.reg, dir, r)
	registry_ensure(&m.reg)
	return n
}

// Load (or reload) the sound effects from the .sfx files in `dir`. Load the
// instruments first: a sound effect can use them. Returns how many.
mixer_load_sounds :: proc(m: ^Mixer, dir := SFX_DIR, rep: ^Load_Report = nil) -> int {
	local: Load_Report
	r := rep != nil ? rep : &local
	defer if rep == nil do report_destroy(&local)
	return sfx_bank_load_dir(&m.sounds, &m.reg, dir, r)
}

// ---------------------------------------------------------------------------
// Songs
// ---------------------------------------------------------------------------

// Load a .song file and play it. Returns 0 if it could not be read (the
// reasons are in `rep`, if given).
mixer_play_song_file :: proc(
	m: ^Mixer,
	path: string,
	loop := true,
	volume: f32 = 1,
	fade_in: f32 = 0,
	rep: ^Load_Report = nil,
) -> Song_Handle {
	local: Load_Report
	r := rep != nil ? rep : &local
	defer if rep == nil do report_destroy(&local)
	song: Song
	song_init(&song)
	if !song_load(path, &song, r) {
		song_destroy(&song)
		return 0
	}
	h := mixer_play_song(m, &song, loop, volume, fade_in)
	slot := slot_get(m, h)
	slot.song = song // the slot keeps it (song-defined instruments live in it)
	slot.owns_song = true
	return h
}

// Play a song that is already in memory. The mixer takes what it needs at this
// moment: later edits to `song` are not heard (except through mixer_sync_song).
// `from_tick` starts part-way in; a looping song then loops back to there.
mixer_play_song :: proc(
	m: ^Mixer,
	song: ^Song,
	loop := true,
	volume: f32 = 1,
	fade_in: f32 = 0,
	from_tick: i32 = 0,
) -> Song_Handle {
	slot := slot_take(m)
	engine_start(&slot.engine, song, from_tick, m.mode)
	engine_set_loop(&slot.engine, loop)
	slot.title = strings.clone(song.title)
	for &t in song.tracks {
		append(&slot.layers, Mixer_Layer {
			name = strings.clone(t.name),
			inst = strings.clone(inst_get(song, t.inst).key),
			base = t.volume,
			on = track_audible(song, &t),
			gain = 1,
		})
	}
	slot_apply(slot)
	slot.goal = max(volume, 0)
	slot_ramp(slot, fade_in)
	slot.level = fade_in > 0 ? 0 : slot.goal
	slot.applied = slot.level * m.music_volume
	m.next_handle += 1
	if m.next_handle == 0 do m.next_handle = 1
	slot.handle = Song_Handle(m.next_handle)
	return slot.handle
}

// Stop a song, faded out over `fade_out` seconds (a few milliseconds at the
// least, so it does not click).
mixer_stop_song :: proc(m: ^Mixer, h: Song_Handle, fade_out: f32 = 0) {
	slot := slot_get(m, h)
	if slot == nil do return
	slot.goal = 0
	slot.stopping = true
	slot_ramp(slot, max(fade_out, 0.01))
}

mixer_stop_all_songs :: proc(m: ^Mixer, fade_out: f32 = 0) {
	for &s in m.songs do if s.handle != 0 do mixer_stop_song(m, s.handle, fade_out)
}

// Still playing (or fading out)?
mixer_song_playing :: proc(m: ^Mixer, h: Song_Handle) -> bool {
	return slot_get(m, h) != nil
}

// Seconds since the song started, and since the current pass of its loop
// started.
mixer_song_time :: proc(m: ^Mixer, h: Song_Handle) -> (total, in_pass: f64) {
	slot := slot_get(m, h)
	if slot == nil do return 0, 0
	return engine_time(&slot.engine)
}

mixer_song_title :: proc(m: ^Mixer, h: Song_Handle) -> string {
	slot := slot_get(m, h)
	return slot != nil ? slot.title : ""
}

// Turn a whole song up or down, over `seconds` (0 = at once).
mixer_set_song_volume :: proc(m: ^Mixer, h: Song_Handle, volume: f32, seconds: f32 = 0) {
	slot := slot_get(m, h)
	if slot == nil || slot.stopping do return
	slot.goal = max(volume, 0)
	slot_ramp(slot, seconds)
}

mixer_set_song_loop :: proc(m: ^Mixer, h: Song_Handle, loop: bool) {
	slot := slot_get(m, h)
	if slot != nil do engine_set_loop(&slot.engine, loop)
}

// ---------------------------------------------------------------------------
// Layers and instruments
//
// Two ways to pick what to turn on or off, ignoring case either way:
//
//   by LAYER, its name as the song gives it:       "Fife 1", "Trumpet 2"
//   by INSTRUMENT, every layer playing it:          "trumpet", "side_drum"
//
// So in british_grenadiers_trumpet.song, mixer_set_layer(.., "Trumpet 1", false)
// silences one part, and mixer_set_instrument(.., "trumpet", false) both
// trumpet parts. The setters return how many layers they changed: 0 means the
// song has nothing by that name (or the song has ended).
// ---------------------------------------------------------------------------

// Turn one layer on or off, by its name.
mixer_set_layer :: proc(m: ^Mixer, h: Song_Handle, name: string, on: bool) -> int {
	return set_on(m, h, .Layer, name, on)
}

// Turn every layer that plays an instrument on or off, by the instrument's
// key: "trumpet", "fife", "side_drum".
mixer_set_instrument :: proc(m: ^Mixer, h: Song_Handle, inst_key: string, on: bool) -> int {
	return set_on(m, h, .Instrument, inst_key, on)
}

// A layer's level on top of its own: 0 silent, 1 as written, 2 twice as loud.
mixer_set_layer_gain :: proc(m: ^Mixer, h: Song_Handle, name: string, gain: f32) -> int {
	return set_gain(m, h, .Layer, name, gain)
}

// The same for every layer playing an instrument.
mixer_set_instrument_gain :: proc(m: ^Mixer, h: Song_Handle, inst_key: string, gain: f32) -> int {
	return set_gain(m, h, .Instrument, inst_key, gain)
}

// This layer on, every other layer off.
mixer_solo_layer :: proc(m: ^Mixer, h: Song_Handle, name: string) -> int {
	return solo(m, h, .Layer, name)
}

// Only the layers playing this instrument on, every other layer off.
mixer_solo_instrument :: proc(m: ^Mixer, h: Song_Handle, inst_key: string) -> int {
	return solo(m, h, .Instrument, inst_key)
}

// Every layer on (the song as written), or every layer off.
mixer_set_all_layers :: proc(m: ^Mixer, h: Song_Handle, on: bool) {
	slot := slot_get(m, h)
	if slot == nil do return
	for &l in slot.layers do l.on = on
	slot_apply(slot)
}

// Is the layer by this name on?
mixer_layer_on :: proc(m: ^Mixer, h: Song_Handle, name: string) -> bool {
	return any_on(m, h, .Layer, name)
}

// Is any layer playing this instrument on?
mixer_instrument_on :: proc(m: ^Mixer, h: Song_Handle, inst_key: string) -> bool {
	return any_on(m, h, .Instrument, inst_key)
}

mixer_layer_count :: proc(m: ^Mixer, h: Song_Handle) -> int {
	slot := slot_get(m, h)
	return slot != nil ? len(slot.layers) : 0
}

// Layer i's name and instrument key, for listing them in a menu.
mixer_layer_name :: proc(m: ^Mixer, h: Song_Handle, i: int) -> (name, inst: string) {
	slot := slot_get(m, h)
	if slot == nil || i < 0 || i >= len(slot.layers) do return "", ""
	return slot.layers[i].name, slot.layers[i].inst
}

mixer_set_layer_index :: proc(m: ^Mixer, h: Song_Handle, i: int, on: bool) {
	slot := slot_get(m, h)
	if slot == nil || i < 0 || i >= len(slot.layers) do return
	slot.layers[i].on = on
	slot_apply(slot)
}

// Follow `song`'s own mute, solo and volume settings (the editor's layer
// panel), as they are now. `song` must be the one the handle was started from.
mixer_sync_song :: proc(m: ^Mixer, h: Song_Handle, song: ^Song) {
	slot := slot_get(m, h)
	if slot == nil do return
	for &t, i in song.tracks {
		if i >= len(slot.layers) do break
		slot.layers[i].on = track_audible(song, &t)
		slot.layers[i].base = t.volume
	}
	slot_apply(slot)
}

// ---------------------------------------------------------------------------
// Sound effects
// ---------------------------------------------------------------------------

// Play a sound effect from the .sfx files. `pan` -1 left .. +1 right; `pitch`
// shifts it in semitones; `vary` picks a random shift up to that many
// semitones either way, so ten musket shots are not one shot ten times.
// Returns 0 if there is no such sound effect.
mixer_play_sfx :: proc(m: ^Mixer, key: string, volume: f32 = 1, pan: f32 = 0, pitch: f32 = 0, vary: f32 = 0) -> Sfx_Handle {
	fx, ok := sfx_find(&m.sounds, key)
	if !ok do return 0
	h := sfx_handle(m)
	shift := pitch + (vary != 0 ? (rand_unit(m) * 2 - 1) * vary : 0)
	for sv in fx.voices {
		ev := sfx_event(sv, fx.volume * volume, pan, shift, m.frame)
		sfx_add(m, voice_make(ev, sv.ins, m.mode), h)
	}
	return h
}

// Many of the same sound effect at once: `count` shots spread over
// `seconds`, clustered along a bell curve - a shot or two alone at first,
// most of them together in the middle, a few stragglers at the end. A line of
// muskets firing a ragged volley, a broadside, a crowd.
//
// Each shot gets its own small differences: pitch (up to `vary` semitones
// either way), loudness (as if some are further away), and place in the
// stereo field (up to `pan_spread` either side). The shots are scaled down as
// a group so a hundred of them do not simply clip: `volume` 1 is about as loud
// as the thickest moment should be. All of them share one handle, so
// mixer_stop_sfx stops the whole burst. `times`, if given, is filled with each
// shot's start in seconds (for drawing them). Returns 0 for an unknown key.
mixer_play_sfx_burst :: proc(
	m: ^Mixer,
	key: string,
	count: int,
	seconds: f32,
	volume: f32 = 1,
	pan_spread: f32 = 0.8,
	vary: f32 = 1,
	times: []f32 = nil,
) -> Sfx_Handle {
	fx, ok := sfx_find(&m.sounds, key)
	if !ok || count <= 0 do return 0
	h := sfx_handle(m)
	span := max(seconds, 0.001)
	// The bell: a normal distribution centred on the middle, 99.7% of it
	// (three standard deviations each way) inside the span; the rare shot
	// outside is drawn again.
	sigma := span / 6
	// How many shots land in the busiest 50 ms, roughly: what they are
	// scaled for.
	peak := f32(count) * 0.05 / (sigma * math.sqrt(f32(2 * math.PI)))
	group := volume / math.sqrt(max(peak, 1))
	for k in 0 ..< count {
		t: f32
		for {
			// Box-Muller.
			u1 := max(rand_unit(m), 1e-6)
			u2 := rand_unit(m)
			z := math.sqrt(-2 * math.ln(u1)) * math.cos(2 * math.PI * u2)
			t = span / 2 + z * sigma
			if t >= 0 && t <= span do break
		}
		if k < len(times) do times[k] = t
		at := m.frame + int(t * RATE)
		shift := (rand_unit(m) * 2 - 1) * vary
		loud := group * (0.55 + 0.45 * rand_unit(m))
		pan := (rand_unit(m) * 2 - 1) * pan_spread
		for sv in fx.voices {
			ev := sfx_event(sv, fx.volume * loud, pan, shift, at)
			sfx_add(m, voice_make(ev, sv.ins, m.mode), h)
		}
	}
	return h
}

// Play one note on an instrument of the orchestra (or of the sound effects),
// by key: a stinger, a bell, a UI blip. `midi` 60 = middle C.
mixer_play_note :: proc(m: ^Mixer, inst_key: string, midi: f32, seconds: f32 = 0.5, volume: f32 = 1, pan: f32 = 0) -> Sfx_Handle {
	if id, ok := registry_find(&m.reg, inst_key); ok {
		return mixer_play_instrument(m, m.reg.list[id], midi, seconds, volume, pan)
	}
	if id, ok := registry_find(&m.sounds.insts, inst_key); ok {
		return mixer_play_instrument(m, m.sounds.insts.list[id], midi, seconds, volume, pan)
	}
	return 0
}

// The same, with the instrument itself (the editor uses this to preview a
// song's own instruments).
mixer_play_instrument :: proc(m: ^Mixer, ins: Instrument, midi: f32, seconds: f32 = 0.5, volume: f32 = 1, pan: f32 = 0) -> Sfx_Handle {
	h := sfx_handle(m)
	ev := Event {
		start = m.frame,
		gate  = max(int(seconds * RATE), 16),
		midi  = midi,
		amp   = volume * ins.gain,
		pan   = clamp(pan, -1, 1),
		track = -1,
	}
	sfx_add(m, voice_make(ev, ins, m.mode), h)
	return h
}

mixer_stop_sfx :: proc(m: ^Mixer, h: Sfx_Handle, fade_out: f32 = 0.02) {
	for &s in m.sfx do if s.handle == h do s.step = 1 / (max(fade_out, 0.005) * RATE)
}

mixer_stop_all_sfx :: proc(m: ^Mixer, fade_out: f32 = 0.02) {
	for &s in m.sfx do s.step = 1 / (max(fade_out, 0.005) * RATE)
}

mixer_sfx_playing :: proc(m: ^Mixer, h: Sfx_Handle) -> bool {
	for s in m.sfx do if s.handle == h do return true
	return false
}

// The keys of every loaded sound effect, for a menu or a test.
mixer_sfx_count :: proc(m: ^Mixer) -> int {return len(m.sounds.list)}
mixer_sfx_key :: proc(m: ^Mixer, i: int) -> (key, name: string) {
	if i < 0 || i >= len(m.sounds.list) do return "", ""
	return m.sounds.list[i].key, m.sounds.list[i].name
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

// Fill `out` (stereo, interleaved, SAMPLE_RATE) with the next block of
// everything that is playing. Any length; the same length every call is best.
mixer_render :: proc(m: ^Mixer, out: []f32) {
	for &s in out do s = 0
	frames := len(out) / 2
	if len(m.scratch) < len(out) do resize(&m.scratch, len(out))
	scratch := m.scratch[:len(out)]

	for &slot in m.songs {
		if slot.handle == 0 do continue
		for &s in scratch do s = 0
		more := engine_render_add(&slot.engine, scratch)
		// Move the song's level toward its goal, across this block.
		if slot.level < slot.goal do slot.level = min(slot.level + slot.step * f32(frames), slot.goal)
		else if slot.level > slot.goal do slot.level = max(slot.level - slot.step * f32(frames), slot.goal)
		g0, g1 := slot.applied, slot.level * m.music_volume
		for i in 0 ..< frames {
			g := g0 + (g1 - g0) * f32(i + 1) / f32(frames)
			out[i * 2] += scratch[i * 2] * g
			out[i * 2 + 1] += scratch[i * 2 + 1] * g
		}
		slot.applied = g1
		if !more || (slot.stopping && slot.level <= 0) do slot_free(&slot)
	}

	block_end := m.frame + frames
	for i := 0; i < len(m.sfx); {
		s := &m.sfx[i]
		if s.voice.ev.start >= block_end {
			// Not started yet (a burst schedules its shots ahead). Stopped
			// before it began: never heard at all.
			if s.step > 0 do unordered_remove(&m.sfx, i)
			else do i += 1
			continue
		}
		offset := max(s.voice.ev.start - m.frame, 0)
		if s.step > 0 do s.level = max(s.level - s.step * f32(frames), 0)
		g1 := s.level * m.sfx_volume
		done := voice_render(&s.voice, out[offset * 2:], s.applied, g1, frames, offset)
		s.applied = g1
		if done || s.level <= 0 {
			unordered_remove(&m.sfx, i) // order does not matter: it is a sum
		} else {
			i += 1
		}
	}

	for &s in out do s = clamp(s * MASTER * m.master, -1, 1)
	m.frame = block_end
}

// ---------------------------------------------------------------------------

@(private)
slot_get :: proc(m: ^Mixer, h: Song_Handle) -> ^Song_Slot {
	if h == 0 do return nil
	for &s in m.songs do if s.handle == h do return &s
	return nil
}

// A free slot; if all are busy, the one closest to finishing gives way.
@(private)
slot_take :: proc(m: ^Mixer) -> ^Song_Slot {
	for &s in m.songs do if s.handle == 0 do return &s
	for &s in m.songs do if s.stopping {slot_free(&s); return &s}
	oldest := &m.songs[0]
	for &s in m.songs do if s.handle < oldest.handle do oldest = &s
	slot_free(oldest)
	return oldest
}

@(private)
slot_free :: proc(s: ^Song_Slot) {
	engine_destroy(&s.engine)
	if s.owns_song do song_destroy(&s.song)
	delete(s.title)
	for l in s.layers {delete(l.name); delete(l.inst)}
	delete(s.layers)
	s^ = {}
}

@(private)
slot_apply :: proc(s: ^Song_Slot) {
	for l, i in s.layers do engine_set_track_gain(&s.engine, i, l.on ? l.base * l.gain : 0)
	// Nothing heard yet: no need to fade, start at the new levels.
	if s.engine.frame == 0 do for &g, i in s.engine.gain do g = s.engine.target[i]
}

@(private)
slot_ramp :: proc(s: ^Song_Slot, seconds: f32) {
	dist := abs(s.goal - s.level)
	s.step = seconds > 0 ? max(dist, 1e-6) / (seconds * RATE) : 1e9
}

@(private)
Match_By :: enum u8 {
	Layer,
	Instrument,
}

@(private)
layer_matches :: proc(l: ^Mixer_Layer, by: Match_By, name: string) -> bool {
	return strings.equal_fold(by == .Layer ? l.name : l.inst, name)
}

@(private)
set_on :: proc(m: ^Mixer, h: Song_Handle, by: Match_By, name: string, on: bool) -> int {
	slot := slot_get(m, h)
	if slot == nil do return 0
	n := 0
	for &l in slot.layers do if layer_matches(&l, by, name) {l.on = on; n += 1}
	slot_apply(slot)
	return n
}

@(private)
set_gain :: proc(m: ^Mixer, h: Song_Handle, by: Match_By, name: string, gain: f32) -> int {
	slot := slot_get(m, h)
	if slot == nil do return 0
	n := 0
	for &l in slot.layers do if layer_matches(&l, by, name) {l.gain = max(gain, 0); n += 1}
	slot_apply(slot)
	return n
}

@(private)
solo :: proc(m: ^Mixer, h: Song_Handle, by: Match_By, name: string) -> int {
	slot := slot_get(m, h)
	if slot == nil do return 0
	n := 0
	for &l in slot.layers {
		l.on = layer_matches(&l, by, name)
		if l.on do n += 1
	}
	slot_apply(slot)
	return n
}

@(private)
any_on :: proc(m: ^Mixer, h: Song_Handle, by: Match_By, name: string) -> bool {
	slot := slot_get(m, h)
	if slot == nil do return false
	for &l in slot.layers do if layer_matches(&l, by, name) && l.on do return true
	return false
}

@(private)
sfx_handle :: proc(m: ^Mixer) -> Sfx_Handle {
	m.next_handle += 1
	if m.next_handle == 0 do m.next_handle = 1
	return Sfx_Handle(m.next_handle)
}

@(private)
sfx_add :: proc(m: ^Mixer, v: Voice, h: Sfx_Handle) {
	voice := v
	// A fresh noise seed each time: two cannon shots should not be identical.
	// (Metallic noise has to stay on its balanced loop: step along it
	// instead of picking a new state.)
	voice.white = rand_u32(m) | 1
	if voice.ins.metallic {
		for _ in 0 ..< rand_u32(m) % 93 {
			lfsr_step(&voice.lfsr, true)
			lfsr_step(&voice.lfsr2, true)
		}
	} else {
		voice.lfsr = (rand_u32(m) & 0x7FFF) | 1
		voice.lfsr2 = (rand_u32(m) & 0x7FFF) | 1
	}
	if len(m.sfx) >= MAX_SFX_VOICES {
		// Full: the voice that started longest ago gives way. If none has
		// started yet, the new one is dropped.
		oldest := -1
		for o, i in m.sfx {
			if o.voice.ev.start > m.frame do continue
			if oldest < 0 || o.voice.ev.start < m.sfx[oldest].voice.ev.start do oldest = i
		}
		if oldest < 0 do return
		unordered_remove(&m.sfx, oldest)
	}
	append(&m.sfx, Sfx_Live{voice = voice, handle = h, level = 1, applied = m.sfx_volume})
}

@(private)
rand_u32 :: proc(m: ^Mixer) -> u32 {
	x := m.rng
	if x == 0 do x = 0x2545F491
	x ~= x << 13
	x ~= x >> 17
	x ~= x << 5
	m.rng = x
	return x
}

@(private)
rand_unit :: proc(m: ^Mixer) -> f32 {
	return f32(rand_u32(m) >> 8) / f32(1 << 24)
}
