package music

/*
    The orchestra.

    Every instrument is built from the same five oscillators the chips had -
    pulse (with a duty cycle), triangle, saw, sine, noise - and what makes a
    cello not a violin is everything AROUND the oscillator: its envelope, its
    vibrato, a second layer, how dark the tone is. DESIGN.md section 2 explains
    each knob.

    NO INSTRUMENT IS DEFINED IN CODE. The whole orchestra lives in the .inst
    files in instruments/ (the format is in instrument_io.odin and
    instruments/README.txt), read at startup and on F7. On top of those, a .song
    can carry `define_instrument` blocks of its own, so it plays the same on any
    copy of the app.

    The files fill one Registry; a song's own definitions live in the Song. A
    track holds an Inst_Id that points into one or the other, and inst_get()
    follows it. Files save the `key` string, never the id, so ids are free to
    change between runs.

    Ranges are SOUNDING pitch as MIDI numbers, so a clarinet's range is where it
    sounds, not where its part is written. The sheet refuses notes outside them.
*/

Wave :: enum u8 {
	Pulse,
	Triangle, // NES style: 16 steps
	Saw,
	Sine,
	Noise, // LFSR, clocked from the note's pitch
}

Family :: enum u8 {
	Strings,
	Woodwinds,
	Brass,
	Percussion,
	Keyboards,
	Voices,
	Chip,
}

FAMILY_NAME := [Family]string {
	.Strings    = "Strings",
	.Woodwinds  = "Woodwinds",
	.Brass      = "Brass",
	.Percussion = "Percussion",
	.Keyboards  = "Keyboards",
	.Voices     = "Voices",
	.Chip       = "Chip",
}

Instrument :: struct {
	key:        string,
	name:       string,
	family:     Family,
	lo, hi:     i32, // sounding MIDI range
	wave:       Wave,
	duty:       f32, // pulse only: 0.125, 0.25, 0.5
	// A second oscillator, mixed in at `mix2`, `semis2` semitones above the
	// first. Organ: the same pulse an octave up. Horn: a softening triangle.
	wave2:      Wave,
	mix2:       f32,
	semis2:     f32,
	// Envelope, seconds / level. Sustain 0 makes a plucked or struck
	// instrument: it decays over `decay` whether the note is held or not.
	attack:     f32,
	decay:      f32,
	sustain:    f32,
	release:    f32,
	// Vibrato: rate in Hz, depth in semitones, starts after `vib_delay` s.
	vib_rate:   f32,
	vib_depth:  f32,
	vib_delay:  f32,
	// Pitch sweep: starts `sweep` semitones off and glides home with this
	// time constant. Negative sweeps up into the note (a trombone's slide).
	sweep:      f32,
	sweep_time: f32,
	breath:     f32, // white noise mixed in (flute breath, bow hiss)
	tone:       f32, // one-pole low-pass: 1 = open, lower = darker
	metallic:   bool, // noise: the NES "short" mode — pitched, clangy
	gain:       f32,
	pan:        f32, // -1 left .. +1 right: orchestral seating
	color:      [4]u8,
	// 32-bit mode only (bowed.odin): a physical model instead of the
	// oscillators, and the body's resonances.
	model:        Model,
	bow_pressure: f32,
	bow_position: f32,
	resonances:   [MAX_RESONANCES]Resonance,
	n_resonances: u8,
	// Where this definition came from - shown in the panel, and what decides
	// whether its strings belong to someone to free.
	origin:     Origin,
	source:     string, // the .inst file, for Origin.File
}

Origin :: enum u8 {
	Fallback, // no instrument files could be found at all: a plain square wave
	File,
	Song,
}

// ---------------------------------------------------------------------------
// The registry: built-ins plus instrument files
// ---------------------------------------------------------------------------

// Which instrument a track plays. Below SONG_INST_BASE: an index into the
// registry. At or above it: an index into the song's own definitions.
Inst_Id :: distinct u16
SONG_INST_BASE :: Inst_Id(0x8000)

Registry :: struct {
	list:    [dynamic]Instrument,
	// Every string a file entry owns, so destroy can free them.
	strings: [dynamic]string,
}

// The registry the app is using. A package variable, so like log.bind in
// Animal Kingdoms it is re-pointed after every hot reload (the library's
// globals are fresh; the registry itself lives in the app's memory block).
@(private)
bound: ^Registry
@(private)
fallback: Registry

registry_bind :: proc(r: ^Registry) {
	bound = r
}

reg :: proc() -> ^Registry {
	if bound != nil do return bound
	registry_ensure(&fallback)
	return &fallback
}

// An empty registry. Fill it with registry_load_dir.
registry_init :: proc(r: ^Registry) {
	registry_destroy(r)
}

registry_destroy :: proc(r: ^Registry) {
	for s in r.strings do delete(s)
	delete(r.strings)
	delete(r.list)
	r^ = {}
}

// Never leave the registry empty: every track needs something to play, even if
// the instruments folder is missing. Returns true if it had to step in.
registry_ensure :: proc(r: ^Registry) -> bool {
	if len(r.list) > 0 do return false
	ins := DEFAULT_INSTRUMENT
	ins.key = "square"
	ins.name = "Square (no instrument files found)"
	ins.origin = .Fallback
	append(&r.list, ins)
	return true
}

// The instrument new layers and unknown keys fall back to: the violin if
// there is one, otherwise whatever came first.
DEFAULT_KEY :: "violin"

default_inst :: proc(s: ^Song = nil) -> Inst_Id {
	if id, ok := inst_find(s, DEFAULT_KEY); ok do return id
	return 0
}

// An instrument by key, or the default one.
inst_or_default :: proc(s: ^Song, key: string) -> Inst_Id {
	if id, ok := inst_find(s, key); ok do return id
	return default_inst(s)
}

// Add an instrument, or replace the one with the same key IN PLACE, so every
// Inst_Id already handed out stays valid.
registry_upsert :: proc(r: ^Registry, ins: Instrument) -> Inst_Id {
	for &e, i in r.list {
		if e.key == ins.key {
			e = ins
			return Inst_Id(i)
		}
	}
	append(&r.list, ins)
	return Inst_Id(len(r.list) - 1)
}

registry_find :: proc(r: ^Registry, key: string) -> (Inst_Id, bool) {
	for e, i in r.list do if e.key == key do return Inst_Id(i), true
	return 0, false
}

// The instrument a track plays. Never nil: an id that points nowhere (a
// definition removed from under a song) plays as the first built-in.
inst_get :: proc(s: ^Song, id: Inst_Id) -> ^Instrument {
	if id >= SONG_INST_BASE {
		i := int(id - SONG_INST_BASE)
		if s != nil && i < len(s.defs) do return &s.defs[i]
	} else {
		r := reg()
		if int(id) < len(r.list) do return &r.list[id]
	}
	r := reg()
	registry_ensure(r)
	return &r.list[0]
}

// Look a key up the way a song does: its own definitions first, then the
// registry.
inst_find :: proc(s: ^Song, key: string) -> (Inst_Id, bool) {
	if s != nil {
		for d, i in s.defs do if d.key == key do return SONG_INST_BASE + Inst_Id(i), true
	}
	return registry_find(reg(), key)
}

// General MIDI program (0-127) to the key of the nearest instrument in the
// standard instrument files. If a key is missing, the import falls back.
inst_from_gm :: proc(program: int) -> string {
	switch program {
	case 0 ..= 5:
		return "piano"
	case 6:
		return "harpsichord"
	case 7:
		return "harpsichord"
	case 8:
		return "celesta"
	case 9, 10, 11:
		return "glockenspiel"
	case 12, 13:
		return "xylophone"
	case 14:
		return "tubular_bells"
	case 15:
		return "xylophone"
	case 16 ..= 23:
		return "organ"
	case 24 ..= 31:
		return "harp"
	case 32 ..= 39:
		return "contrabass"
	case 40:
		return "violin"
	case 41:
		return "viola"
	case 42:
		return "cello"
	case 43:
		return "contrabass"
	case 44, 45, 48, 49, 50, 51:
		return "violin"
	case 46:
		return "harp"
	case 47:
		return "timpani"
	case 52 ..= 54:
		return "choir"
	case 55:
		return "trumpet"
	case 56, 59:
		return "trumpet"
	case 57:
		return "trombone"
	case 58:
		return "tuba"
	case 60, 61, 62, 63:
		return "horn"
	case 64, 65:
		return "clarinet"
	case 66, 67:
		return "bassoon"
	case 68:
		return "oboe"
	case 69:
		return "english_horn"
	case 70:
		return "bassoon"
	case 71:
		return "clarinet"
	case 72:
		return "piccolo"
	case 73 ..= 79:
		return "flute"
	case 80, 81:
		return "square_lead"
	case 87:
		return "triangle_bass"
	case 82 ..= 86, 88 ..= 95:
		return "pulse_lead"
	case 112:
		return "tubular_bells"
	case 113 ..= 119:
		return "snare"
	}
	return "pulse_lead"
}
