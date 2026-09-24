package music

/*
    The synthesiser.

    Grown out of sounds_example.odin, which made every sound as maths on a
    sample buffer: tones, noise, fades, a one-pole "muffle". Same ingredients,
    two changes:

      * It is a BLOCK ENGINE. The song is flattened into note events; each call
        to engine_render fills one block, starting the voices that fall in it
        and retiring the ones that have finished. Live playback feeds those
        blocks to an audio stream, so pressing Play is instant however long the
        song is; export just runs the same engine to the end.

      * The oscillators are the chip's: pulse with a duty cycle, a 16-step
        triangle, saw, sine, and an LFSR noise channel. Pulse and saw are
        band-limited with PolyBLEP so a piccolo does not alias into a screech;
        the triangle keeps its staircase on purpose, that IS the NES bass.

    Output is stereo, interleaved (L R L R ...), f32 in -1..1.

    LIVE MIX. Every track's notes are in the engine from the start, muted or
    not, and each track has a gain (0..1) applied as it plays. So a track can be
    muted, soloed or turned up mid-song and the change is heard within one
    block, faded rather than cut:

        engine_set_track_gain(&e, track, 0)    // this track, directly
        engine_sync_mix(&e, &song)             // or: follow the song's own
                                               // mute / solo / volume settings

    A muted note keeps its place (it is counted, not synthesised), so unmuting
    in the middle of a held note brings the rest of that note in.

    USING THIS FROM ANOTHER PROGRAM. This package has no raylib in it. To play
    a song in a game: registry_load_dir the instruments, song_load the song,
    engine_start, then keep calling engine_render for blocks of stereo f32 and
    hand them to your audio output (the editor's player.odin does exactly that
    with a raylib AudioStream). song_track_index finds a layer by name.
*/

import "core:math"
import "core:slice"

SAMPLE_RATE :: 44100
RATE :: f32(SAMPLE_RATE)
TAU :: 2 * math.PI

// Pitch modulation (vibrato, sweep) is recomputed this often, not per sample.
CONTROL_FRAMES :: 32

// Everything mixed is scaled by this before clamping, so twenty instruments
// playing at once do not simply clip.
MASTER :: f32(0.32)

Event :: struct {
	start:   int, // frame the note begins
	gate:    int, // frames it is held
	inst:    u16, // index into Engine.insts
	midi:    f32,
	amp:     f32, // velocity × track volume × instrument gain
	pan:     f32,
	// Where it came from, so the sheet can light it up.
	track:   int,
	note:    int,
}

Voice :: struct {
	ev:        Event,
	// A copy, not a pointer: the instrument files can be reloaded (F7)
	// mid-note, and a voice keeps the sound it started with.
	ins:       Instrument,
	age:       int,
	life:      int, // gate + release, in frames
	phase:     f32,
	phase2:    f32,
	lp:        f32,
	lfsr:      u32,
	lfsr2:     u32,
	nclock:    f32,
	nclock2:   f32,
	nout:      f32,
	nout2:     f32,
	// The breath noise's own generator. Per voice, seeded from the note, so a
	// note sounds the same whatever else is playing - or muted - around it.
	white:     u32,
	freq:      f32,
	gl, gr:    f32,
	release_from: f32,
}

Engine :: struct {
	events: [dynamic]Event,
	// The instrument of each track, copied when playback starts.
	insts:  [dynamic]Instrument,
	// Per track: the gain being played now, and the one it is heading for.
	// A block ramps from one to the other, so changes fade instead of click.
	gain:   [dynamic]f32,
	target: [dynamic]f32,
	next:   int,
	voices: [dynamic]Voice,
	frame:  int,
	crush:  bool, // quantise volume to 16 levels, as the NES did
}

// Flatten `song` from `from_tick` onwards. Notes already sounding at
// `from_tick` are started, shortened, so starting mid-phrase is not silent.
engine_start :: proc(e: ^Engine, song: ^Song, from_tick: i32 = 0, crush := true) {
	engine_destroy(e)
	e.crush = crush
	spt := tick_seconds(song)
	for &t, ti in song.tracks {
		append(&e.insts, inst_get(song, t.inst)^)
		g := track_audible(song, &t) ? t.volume : 0
		append(&e.gain, g)
		append(&e.target, g)
		ins := e.insts[ti]
		for n, ni in t.notes {
			end := n.tick + n.len
			if end <= from_tick do continue
			start := max(n.tick, from_tick)
			secs := f64(end - start) * spt
			// A little air between repeated notes, or two quarter notes on
			// the same pitch play as one half note.
			secs -= min(0.025, secs * 0.12)
			append(&e.events, Event{
				start = int(f64(start - from_tick) * spt * SAMPLE_RATE),
				gate = max(int(secs * SAMPLE_RATE), 64),
				inst = u16(ti),
				midi = f32(pitch_midi(n.pitch)),
				amp = f32(n.vel) / 127 * ins.gain, // the track's volume is its gain
				pan = clamp(t.pan, -1, 1),
				track = ti,
				note = ni,
			})
		}
	}
	slice.sort_by(e.events[:], proc(a, b: Event) -> bool {return a.start < b.start})
}

engine_destroy :: proc(e: ^Engine) {
	delete(e.events)
	delete(e.insts)
	delete(e.gain)
	delete(e.target)
	delete(e.voices)
	e^ = {}
}

// Turn one track up or down while it plays: 0 = silent, 1 = full. Heard from
// the next block, faded in or out across it.
engine_set_track_gain :: proc(e: ^Engine, track: int, gain: f32) {
	if track < 0 || track >= len(e.target) do return
	e.target[track] = max(gain, 0)
}

// Follow the song's mute, solo and volume settings, as they are right now.
// Cheap: call it every frame. Tracks added after engine_start are not in the
// engine (their notes were not collected) and are ignored.
engine_sync_mix :: proc(e: ^Engine, song: ^Song) {
	for &t, i in song.tracks {
		if i >= len(e.target) do break
		e.target[i] = track_audible(song, &t) ? t.volume : 0
	}
}

// Is there anything left to play?
engine_done :: proc(e: ^Engine) -> bool {
	return e.next >= len(e.events) && len(e.voices) == 0
}

// Fill `out` (stereo, interleaved) with the next block. Returns false once the
// song has completely finished ringing.
engine_render :: proc(e: ^Engine, out: []f32) -> bool {
	slice.fill(out, 0)
	frames := len(out) / 2
	block_end := e.frame + frames

	for e.next < len(e.events) && e.events[e.next].start < block_end {
		ev := e.events[e.next]
		append(&e.voices, voice_make(ev, e.insts[ev.inst]))
		e.next += 1
	}

	for i := len(e.voices) - 1; i >= 0; i -= 1 {
		v := &e.voices[i]
		offset := max(v.ev.start - e.frame, 0)
		tr := int(v.ev.inst)
		g0, g1 := e.gain[tr], e.target[tr]
		done: bool
		if g0 == 0 && g1 == 0 {
			// Muted all block: keep time, skip the synthesis.
			v.age += frames - offset
			done = v.age >= v.life
		} else {
			done = voice_render(v, out[offset * 2:], e.crush, g0, g1, frames, offset)
		}
		if done do unordered_remove(&e.voices, i)
	}
	for &g, i in e.gain do g = e.target[i]

	for &s in out do s = clamp(s * MASTER, -1, 1)
	e.frame = block_end
	return !engine_done(e)
}

// Render a whole song into one buffer: export and the render tool.
render_song :: proc(song: ^Song, crush := true, allocator := context.allocator) -> []f32 {
	e: Engine
	engine_start(&e, song, 0, crush)
	defer engine_destroy(&e)
	out := make([dynamic]f32, allocator)
	block: [2048 * 2]f32
	for engine_render(&e, block[:]) {
		append(&out, ..block[:])
	}
	append(&out, ..block[:]) // the final block, and a moment of silence
	return out[:]
}

// One note on its own, for the click you hear when placing it.
render_preview :: proc(ins: Instrument, p: Pitch, seconds: f32 = 0.35, allocator := context.allocator) -> []f32 {
	ev := Event {
		gate = int(seconds * RATE),
		midi = f32(pitch_midi(p)),
		amp  = 0.8 * ins.gain,
		pan  = 0,
	}
	v := voice_make(ev, ins)
	out := make([]f32, v.life * 2, allocator)
	voice_render(&v, out, true, 1, 1, 1, 0)
	for &s in out do s = clamp(s * MASTER * 1.6, -1, 1)
	return out
}

// Scale so the loudest sample is `peak`. For export: live playback can't know
// the loudest moment in advance, a finished file can.
normalize :: proc(s: []f32, peak: f32 = 0.9) {
	loudest: f32
	for v in s do loudest = max(loudest, abs(v))
	if loudest > 0 do for &v in s do v *= peak / loudest
}

// ---------------------------------------------------------------------------
// A voice
// ---------------------------------------------------------------------------

@(private)
voice_make :: proc(ev: Event, ins: Instrument) -> Voice {
	v := Voice {
		ev    = ev,
		ins   = ins,
		lfsr  = 1,
		lfsr2 = 0x5A5A,
		freq  = midi_freq(ev.midi),
		white = 0x9E3779B9 ~ u32(ev.start) * 2654435761 ~ u32(ev.track) * 40503 ~ u32(ev.midi * 8),
	}
	if v.white == 0 do v.white = 1
	v.life = ev.gate + int(max(ins.release, 0.005) * RATE)
	// A struck or plucked note rings for its decay whatever its written
	// length, as a harp string does.
	if ins.sustain <= 0 do v.life = max(v.life, int((ins.attack + ins.decay) * RATE))
	// Constant-power pan.
	a := (v.ev.pan + 1) * math.PI / 4
	v.gl, v.gr = math.cos(a), math.sin(a)
	return v
}

// Envelope level at time t (seconds), note held for `gate` seconds.
@(private)
envelope :: proc(ins: ^Instrument, t, gate: f32) -> f32 {
	held :: proc(ins: ^Instrument, t: f32) -> f32 {
		if t < ins.attack do return t / max(ins.attack, 1e-4)
		d := t - ins.attack
		if ins.sustain <= 0 {
			// Struck: an exponential fall, which is what a real decay is.
			return math.exp(-d * 4.6 / max(ins.decay, 1e-3))
		}
		if d < ins.decay do return 1 - (1 - ins.sustain) * d / max(ins.decay, 1e-4)
		return ins.sustain
	}
	if ins.sustain <= 0 {
		// Plucked notes ignore the gate until their own decay has run.
		return held(ins, t) * (t > gate + ins.decay ? 0 : 1)
	}
	if t < gate do return held(ins, t)
	r := (t - gate) / max(ins.release, 1e-3)
	return r >= 1 ? 0 : held(ins, gate) * (1 - r)
}

// PolyBLEP: rounds off the corner of a jump so it does not alias.
@(private)
blep :: #force_inline proc(t, dt: f32) -> f32 {
	if t < dt {
		x := t / dt
		return x + x - x * x - 1
	} else if t > 1 - dt {
		x := (t - 1) / dt
		return x * x + x + x + 1
	}
	return 0
}

@(private)
fract :: #force_inline proc(x: f32) -> f32 {
	return x - math.floor(x)
}

@(private)
osc :: #force_inline proc(w: Wave, ph, dt, duty: f32, noise_out: f32) -> f32 {
	switch w {
	case .Pulse:
		v: f32 = ph < duty ? 1 : -1
		v += blep(ph, dt)
		v -= blep(fract(ph + 1 - duty), dt)
		// Keep the pulse centred whatever its duty, or a 12.5% pulse is
		// mostly a DC offset.
		return v - (2 * duty - 1)
	case .Triangle:
		tri := 4 * abs(ph - 0.5) - 1 // -1..1
		return math.floor((tri + 1) * 7.5 + 0.5) / 7.5 - 1 // 16 steps
	case .Saw:
		return 2 * ph - 1 - blep(ph, dt)
	case .Sine:
		return math.sin(TAU * ph)
	case .Noise:
		return noise_out
	}
	return 0
}

// The NES noise channel: a 15-bit shift register. Tap 1 is hiss; tap 6 (the
// "short" mode) repeats every 93 steps and sounds metallic.
@(private)
lfsr_step :: #force_inline proc(r: ^u32, metallic: bool) -> f32 {
	tap: u32 = metallic ? 6 : 1
	bit := (r^ ~ (r^ >> tap)) & 1
	r^ = (r^ >> 1) | (bit << 14)
	return (r^ & 1) == 1 ? 1 : -1
}

// Render into `out` from its start. Returns true when the voice is finished.
@(private)
// `g0`..`g1` is the track's gain ramp across the block; this voice starts
// `ramp_at` frames into a block of `ramp_len`.
voice_render :: proc(v: ^Voice, out: []f32, crush: bool, g0, g1: f32, ramp_len, ramp_at: int) -> bool {
	ins := &v.ins
	frames := len(out) / 2
	gate := f32(v.ev.gate) / RATE
	ratio2 := math.pow(2, ins.semis2 / 12)
	f := v.freq
	for i in 0 ..< frames {
		if v.age >= v.life do return true
		t := f32(v.age) / RATE

		if v.age % CONTROL_FRAMES == 0 {
			semis: f32 = 0
			if ins.vib_depth > 0 && t > ins.vib_delay {
				fade_in := min((t - ins.vib_delay) / 0.25, 1)
				semis += ins.vib_depth * fade_in * math.sin(TAU * ins.vib_rate * (t - ins.vib_delay))
			}
			if ins.sweep != 0 do semis += ins.sweep * math.exp(-t / max(ins.sweep_time, 1e-3))
			f = v.freq * math.pow(2, semis / 12)
		}

		dt := f / RATE
		dt2 := dt * ratio2

		// Noise is clocked by the pitch: higher rows, brighter hiss.
		if ins.wave == .Noise {
			v.nclock += dt * 8
			for v.nclock >= 1 {v.nclock -= 1; v.nout = lfsr_step(&v.lfsr, ins.metallic)}
		}
		if ins.mix2 > 0 && ins.wave2 == .Noise {
			v.nclock2 += dt2 * 8
			for v.nclock2 >= 1 {v.nclock2 -= 1; v.nout2 = lfsr_step(&v.lfsr2, ins.metallic)}
		}

		s := osc(ins.wave, v.phase, dt, ins.duty, v.nout)
		if ins.mix2 > 0 {
			s = s * (1 - ins.mix2) + osc(ins.wave2, v.phase2, dt2, ins.duty, v.nout2) * ins.mix2
		}
		if ins.breath > 0 {
			v.white ~= v.white << 13
			v.white ~= v.white >> 17
			v.white ~= v.white << 5
			s += ins.breath * (f32(v.white) / f32(max(u32)) * 2 - 1)
		}

		v.phase = fract(v.phase + dt)
		v.phase2 = fract(v.phase2 + dt2)

		// The muffle from sounds_example: one pole, 1 = open.
		v.lp += clamp(ins.tone, 0.01, 1) * (s - v.lp)

		env := envelope(ins, t, gate)
		if crush do env = math.round(env * 15) / 15
		a := v.lp * env * v.ev.amp
		if g0 == g1 {
			a *= g0
		} else {
			a *= g0 + (g1 - g0) * min(f32(i + ramp_at) / f32(ramp_len), 1)
		}
		out[i * 2] += a * v.gl
		out[i * 2 + 1] += a * v.gr
		v.age += 1
	}
	return v.age >= v.life
}
