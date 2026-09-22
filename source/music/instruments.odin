package music

/*
    The orchestra.

    Every instrument is built from the same five oscillators the chips had —
    pulse (with a duty cycle), triangle, saw, sine, noise — and what makes a
    cello not a violin is everything AROUND the oscillator: its envelope, its
    vibrato, a second layer, how dark the tone is. DESIGN.md section 2 explains
    each knob; this table is where they are turned.

    Ranges are SOUNDING pitch as MIDI numbers, so a clarinet's range is where it
    sounds, not where its part is written. The sheet refuses notes outside them.

    Keyed by an enum so the table is a constant the hot-reloaded library can
    rebuild identically; the `key` string is what goes in a .song file, so the
    enum can be reordered without breaking saved songs.
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

Inst :: enum u8 {
	Violin,
	Viola,
	Cello,
	Contrabass,
	Harp,
	Piccolo,
	Flute,
	Oboe,
	English_Horn,
	Clarinet,
	Bass_Clarinet,
	Bassoon,
	Contrabassoon,
	Horn,
	Trumpet,
	Trombone,
	Tuba,
	Timpani,
	Glockenspiel,
	Xylophone,
	Tubular_Bells,
	Snare,
	Bass_Drum,
	Cymbals,
	Piano,
	Harpsichord,
	Celesta,
	Organ,
	Choir,
	Pulse_Lead,
	Square_Lead,
	Triangle_Bass,
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
}

INSTRUMENTS := [Inst]Instrument {
	// --- Strings: saw waves, a quick bow attack, vibrato arriving late ---
	.Violin = {key = "violin", name = "Violin", family = .Strings, lo = 55, hi = 103,
		wave = .Saw, attack = 0.03, decay = 0.1, sustain = 0.85, release = 0.08,
		vib_rate = 5.8, vib_depth = 0.14, vib_delay = 0.18, breath = 0.02, tone = 0.55,
		gain = 0.55, pan = -0.45, color = {236, 112, 84, 255}},
	.Viola = {key = "viola", name = "Viola", family = .Strings, lo = 48, hi = 88,
		wave = .Saw, attack = 0.04, decay = 0.1, sustain = 0.85, release = 0.1,
		vib_rate = 5.5, vib_depth = 0.13, vib_delay = 0.2, breath = 0.02, tone = 0.42,
		gain = 0.55, pan = 0.1, color = {232, 146, 70, 255}},
	.Cello = {key = "cello", name = "Cello", family = .Strings, lo = 36, hi = 81,
		wave = .Saw, attack = 0.05, decay = 0.12, sustain = 0.85, release = 0.12,
		vib_rate = 5.2, vib_depth = 0.12, vib_delay = 0.22, breath = 0.015, tone = 0.32,
		gain = 0.6, pan = 0.35, color = {200, 70, 130, 255}},
	.Contrabass = {key = "contrabass", name = "Contrabass", family = .Strings, lo = 28, hi = 67,
		wave = .Pulse, duty = 0.5, wave2 = .Saw, mix2 = 0.4, attack = 0.05, decay = 0.15,
		sustain = 0.8, release = 0.12, vib_rate = 4.8, vib_depth = 0.08, vib_delay = 0.3,
		tone = 0.22, gain = 0.7, pan = 0.55, color = {176, 70, 58, 255}},
	.Harp = {key = "harp", name = "Harp", family = .Strings, lo = 24, hi = 103,
		wave = .Triangle, wave2 = .Pulse, duty = 0.5, mix2 = 0.15, semis2 = 12,
		attack = 0.002, decay = 1.6, sustain = 0, release = 0.4, tone = 0.7,
		gain = 0.7, pan = -0.6, color = {246, 190, 120, 255}},

	// --- Woodwinds: triangles that breathe, pulses of every width ---
	.Piccolo = {key = "piccolo", name = "Piccolo", family = .Woodwinds, lo = 74, hi = 108,
		wave = .Triangle, attack = 0.02, decay = 0.1, sustain = 0.8, release = 0.06,
		vib_rate = 6, vib_depth = 0.1, vib_delay = 0.15, breath = 0.07, tone = 0.8,
		gain = 0.55, pan = -0.2, color = {150, 230, 120, 255}},
	.Flute = {key = "flute", name = "Flute", family = .Woodwinds, lo = 60, hi = 96,
		wave = .Triangle, wave2 = .Sine, mix2 = 0.3, attack = 0.035, decay = 0.1,
		sustain = 0.85, release = 0.08, vib_rate = 5.5, vib_depth = 0.12, vib_delay = 0.2,
		breath = 0.06, tone = 0.75, gain = 0.75, pan = -0.15, color = {120, 214, 110, 255}},
	.Oboe = {key = "oboe", name = "Oboe", family = .Woodwinds, lo = 58, hi = 91,
		wave = .Pulse, duty = 0.125, attack = 0.025, decay = 0.08, sustain = 0.8,
		release = 0.06, vib_rate = 5.2, vib_depth = 0.08, vib_delay = 0.2, tone = 0.6,
		gain = 0.45, pan = 0.15, color = {92, 196, 140, 255}},
	.English_Horn = {key = "english_horn", name = "English Horn", family = .Woodwinds, lo = 52, hi = 84,
		wave = .Pulse, duty = 0.125, attack = 0.03, decay = 0.1, sustain = 0.8,
		release = 0.08, vib_rate = 5, vib_depth = 0.08, vib_delay = 0.22, tone = 0.4,
		gain = 0.5, pan = 0.2, color = {70, 170, 120, 255}},
	.Clarinet = {key = "clarinet", name = "Clarinet", family = .Woodwinds, lo = 50, hi = 94,
		wave = .Pulse, duty = 0.5, attack = 0.03, decay = 0.1, sustain = 0.85,
		release = 0.06, vib_depth = 0, tone = 0.5, breath = 0.01,
		gain = 0.45, pan = -0.1, color = {160, 206, 70, 255}},
	.Bass_Clarinet = {key = "bass_clarinet", name = "Bass Clarinet", family = .Woodwinds, lo = 38, hi = 77,
		wave = .Pulse, duty = 0.5, attack = 0.035, decay = 0.1, sustain = 0.85,
		release = 0.08, tone = 0.3, breath = 0.01, gain = 0.5, pan = -0.05,
		color = {120, 160, 60, 255}},
	.Bassoon = {key = "bassoon", name = "Bassoon", family = .Woodwinds, lo = 34, hi = 75,
		wave = .Pulse, duty = 0.25, attack = 0.03, decay = 0.1, sustain = 0.8,
		release = 0.07, vib_rate = 4.8, vib_depth = 0.05, vib_delay = 0.25, tone = 0.3,
		gain = 0.5, pan = 0.1, color = {100, 150, 90, 255}},
	.Contrabassoon = {key = "contrabassoon", name = "Contrabassoon", family = .Woodwinds, lo = 22, hi = 53,
		wave = .Pulse, duty = 0.25, attack = 0.04, decay = 0.1, sustain = 0.8,
		release = 0.08, tone = 0.2, gain = 0.6, pan = 0.1, color = {80, 120, 70, 255}},

	// --- Brass: pulses and saws that swell in ---
	.Horn = {key = "horn", name = "French Horn", family = .Brass, lo = 34, hi = 77,
		wave = .Pulse, duty = 0.5, wave2 = .Triangle, mix2 = 0.45, attack = 0.07,
		decay = 0.15, sustain = 0.85, release = 0.12, vib_rate = 4.5, vib_depth = 0.05,
		vib_delay = 0.3, tone = 0.3, gain = 0.6, pan = -0.3, color = {240, 200, 70, 255}},
	.Trumpet = {key = "trumpet", name = "Trumpet", family = .Brass, lo = 52, hi = 84,
		wave = .Pulse, duty = 0.25, attack = 0.015, decay = 0.08, sustain = 0.85,
		release = 0.05, vib_rate = 5.5, vib_depth = 0.07, vib_delay = 0.25,
		sweep = -0.6, sweep_time = 0.02, tone = 0.7, gain = 0.45, pan = 0.25,
		color = {255, 222, 90, 255}},
	.Trombone = {key = "trombone", name = "Trombone", family = .Brass, lo = 40, hi = 72,
		wave = .Saw, attack = 0.03, decay = 0.1, sustain = 0.85, release = 0.08,
		sweep = -0.8, sweep_time = 0.03, tone = 0.4, gain = 0.5, pan = 0.35,
		color = {220, 170, 50, 255}},
	.Tuba = {key = "tuba", name = "Tuba", family = .Brass, lo = 26, hi = 65,
		wave = .Pulse, duty = 0.5, wave2 = .Triangle, mix2 = 0.5, attack = 0.04,
		decay = 0.12, sustain = 0.85, release = 0.1, tone = 0.22, gain = 0.7,
		pan = 0.45, color = {190, 140, 40, 255}},

	// --- Percussion ---
	.Timpani = {key = "timpani", name = "Timpani", family = .Percussion, lo = 38, hi = 57,
		wave = .Triangle, wave2 = .Noise, mix2 = 0.2, semis2 = 24, attack = 0.002,
		decay = 1.1, sustain = 0, release = 0.3, sweep = 3, sweep_time = 0.04,
		tone = 0.4, gain = 0.9, pan = 0, color = {170, 150, 220, 255}},
	.Glockenspiel = {key = "glockenspiel", name = "Glockenspiel", family = .Percussion, lo = 79, hi = 108,
		wave = .Sine, wave2 = .Sine, mix2 = 0.3, semis2 = 24, attack = 0.001, decay = 1.2,
		sustain = 0, release = 0.5, tone = 1, gain = 0.9, pan = 0.3,
		color = {200, 190, 255, 255}},
	.Xylophone = {key = "xylophone", name = "Xylophone", family = .Percussion, lo = 65, hi = 108,
		wave = .Triangle, wave2 = .Sine, mix2 = 0.3, semis2 = 19, attack = 0.001,
		decay = 0.25, sustain = 0, release = 0.08, tone = 0.9, gain = 1.4, pan = 0.3,
		color = {190, 160, 240, 255}},
	.Tubular_Bells = {key = "tubular_bells", name = "Tubular Bells", family = .Percussion, lo = 60, hi = 77,
		wave = .Sine, wave2 = .Sine, mix2 = 0.35, semis2 = 15.3, attack = 0.001,
		decay = 2.5, sustain = 0, release = 1, tone = 1, gain = 0.6, pan = -0.3,
		color = {220, 210, 255, 255}},
	.Snare = {key = "snare", name = "Snare Drum", family = .Percussion, lo = 55, hi = 79,
		wave = .Noise, wave2 = .Triangle, mix2 = 0.25, semis2 = -24, attack = 0.001,
		decay = 0.18, sustain = 0, release = 0.05, tone = 0.8, gain = 0.8, pan = 0.1,
		color = {150, 140, 180, 255}},
	.Bass_Drum = {key = "bass_drum", name = "Bass Drum", family = .Percussion, lo = 28, hi = 43,
		wave = .Triangle, attack = 0.001, decay = 0.35, sustain = 0, release = 0.05,
		sweep = 12, sweep_time = 0.03, tone = 0.6, gain = 1, pan = 0,
		color = {120, 110, 160, 255}},
	.Cymbals = {key = "cymbals", name = "Cymbals", family = .Percussion, lo = 72, hi = 96,
		wave = .Noise, metallic = true, wave2 = .Noise, mix2 = 0.5, semis2 = 7, attack = 0.001,
		decay = 0.9, sustain = 0, release = 0.3, tone = 1, gain = 0.45, pan = -0.2,
		color = {210, 200, 230, 255}},

	// --- Keyboards ---
	.Piano = {key = "piano", name = "Piano", family = .Keyboards, lo = 21, hi = 108,
		wave = .Pulse, duty = 0.25, wave2 = .Triangle, mix2 = 0.4, attack = 0.002,
		decay = 1.4, sustain = 0.15, release = 0.25, tone = 0.55, gain = 0.6, pan = 0,
		color = {110, 170, 250, 255}},
	.Harpsichord = {key = "harpsichord", name = "Harpsichord", family = .Keyboards, lo = 29, hi = 89,
		wave = .Pulse, duty = 0.125, wave2 = .Pulse, mix2 = 0.3, semis2 = 12, attack = 0.001,
		decay = 0.8, sustain = 0, release = 0.15, tone = 0.8, gain = 0.8, pan = 0,
		color = {140, 190, 240, 255}},
	.Celesta = {key = "celesta", name = "Celesta", family = .Keyboards, lo = 60, hi = 108,
		wave = .Sine, wave2 = .Triangle, mix2 = 0.25, semis2 = 12, attack = 0.002,
		decay = 0.9, sustain = 0, release = 0.3, tone = 1, gain = 0.9, pan = 0.2,
		color = {160, 210, 255, 255}},
	.Organ = {key = "organ", name = "Organ", family = .Keyboards, lo = 24, hi = 96,
		wave = .Pulse, duty = 0.5, wave2 = .Pulse, mix2 = 0.45, semis2 = 12, attack = 0.01,
		decay = 0.01, sustain = 1, release = 0.05, tone = 0.45, gain = 0.4, pan = 0,
		color = {80, 140, 230, 255}},

	// --- Voices ---
	.Choir = {key = "choir", name = "Choir", family = .Voices, lo = 40, hi = 81,
		wave = .Pulse, duty = 0.5, wave2 = .Triangle, mix2 = 0.5, semis2 = 0.08,
		attack = 0.12, decay = 0.2, sustain = 0.85, release = 0.2, vib_rate = 5,
		vib_depth = 0.18, vib_delay = 0.15, breath = 0.03, tone = 0.3, gain = 0.5,
		pan = 0, color = {240, 140, 200, 255}},

	// --- Chip: the NES channels, as they were ---
	.Pulse_Lead = {key = "pulse_lead", name = "Pulse Lead", family = .Chip, lo = 36, hi = 96,
		wave = .Pulse, duty = 0.25, attack = 0.002, decay = 0.1, sustain = 0.75,
		release = 0.03, vib_rate = 6, vib_depth = 0.1, vib_delay = 0.25, tone = 1,
		gain = 0.4, pan = 0, color = {90, 230, 230, 255}},
	.Square_Lead = {key = "square_lead", name = "Square Lead", family = .Chip, lo = 36, hi = 96,
		wave = .Pulse, duty = 0.5, attack = 0.002, decay = 0.1, sustain = 0.75,
		release = 0.03, tone = 1, gain = 0.4, pan = 0, color = {70, 200, 210, 255}},
	.Triangle_Bass = {key = "triangle_bass", name = "Triangle Bass", family = .Chip, lo = 21, hi = 72,
		wave = .Triangle, attack = 0.002, decay = 0.05, sustain = 1, release = 0.02,
		tone = 1, gain = 0.6, pan = 0, color = {60, 170, 190, 255}},
}

inst_from_key :: proc(key: string) -> (Inst, bool) {
	for ins, id in INSTRUMENTS do if ins.key == key do return id, true
	return .Violin, false
}

// General MIDI program (0-127) to the nearest instrument we have.
inst_from_gm :: proc(program: int) -> Inst {
	switch program {
	case 0 ..= 5:
		return .Piano
	case 6:
		return .Harpsichord
	case 7:
		return .Harpsichord
	case 8:
		return .Celesta
	case 9, 10, 11:
		return .Glockenspiel
	case 12, 13:
		return .Xylophone
	case 14:
		return .Tubular_Bells
	case 15:
		return .Xylophone
	case 16 ..= 23:
		return .Organ
	case 24 ..= 31:
		return .Harp
	case 32 ..= 39:
		return .Contrabass
	case 40:
		return .Violin
	case 41:
		return .Viola
	case 42:
		return .Cello
	case 43:
		return .Contrabass
	case 44, 45, 48, 49, 50, 51:
		return .Violin
	case 46:
		return .Harp
	case 47:
		return .Timpani
	case 52 ..= 54:
		return .Choir
	case 55:
		return .Trumpet
	case 56, 59:
		return .Trumpet
	case 57:
		return .Trombone
	case 58:
		return .Tuba
	case 60, 61, 62, 63:
		return .Horn
	case 64, 65:
		return .Clarinet
	case 66, 67:
		return .Bassoon
	case 68:
		return .Oboe
	case 69:
		return .English_Horn
	case 70:
		return .Bassoon
	case 71:
		return .Clarinet
	case 72:
		return .Piccolo
	case 73 ..= 79:
		return .Flute
	case 80, 81:
		return .Square_Lead
	case 87:
		return .Triangle_Bass
	case 82 ..= 86, 88 ..= 95:
		return .Pulse_Lead
	case 112:
		return .Tubular_Bells
	case 113 ..= 119:
		return .Snare
	}
	return .Pulse_Lead
}
