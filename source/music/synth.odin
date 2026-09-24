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

    USING THIS FROM ANOTHER PROGRAM. Use the Mixer (mixer.odin): it plays
    songs (looping, fading, several at once), mutes layers by name, and plays
    sound effects on top. The Engine below is the layer underneath it: one song,
    rendered block by block.

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

// How the orchestra is rendered. The instruments are the same in every mode;
// what changes is how much of the old hardware's roughness is kept, and from
// 16-bit up, how much of a real player's is added.
//
//   4-bit    volume in 16 steps, as the NES did: the grittiest
//   8-bit    the chip oscillators, smooth volume (the default)
//   16-bit   8-bit plus what a player adds: every note a few cents off,
//            vibrato that is never quite regular, a scratch of bow or a
//            chiff of breath at the start (instruments with breath), and a
//            smooth triangle instead of the NES's 16-step one
//   32-bit   16-bit plus physical models where an instrument has one
//            (`model bowed`: a bowed string, simulated) and the body's
//            resonances (`resonance` lines: the wooden box around it)
Sound_Mode :: enum u8 {
	Bit4,
	Bit8,
	Bit16,
	Bit32,
}

SOUND_MODE_NAME := [Sound_Mode]string {
	.Bit4  = "4-bit",
	.Bit8  = "8-bit",
	.Bit16 = "16-bit",
	.Bit32 = "32-bit",
}

DEFAULT_MODE :: Sound_Mode.Bit8

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
	// The frequency now, vibrato and sweep included: recomputed every
	// CONTROL_FRAMES, and kept here so it carries across blocks.
	f_now:     f32,
	gl, gr:    f32,
	release_from: f32,
	mode:      Sound_Mode,
	// 16-bit and up: this note's own small imperfections.
	vib_k:     [2]f32, // rate and depth, scaled
	wander:    [2]f32, // phases of a slow, irregular pitch drift
	// 32-bit: the bowed string (bowed.odin) and the body filters.
	bow:       Bowed,
	body:      [MAX_RESONANCES]Biquad,
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
	mode:   Sound_Mode,
	// Looping: after `loop_len` frames the events start over. `loop_base` is
	// the frame the current pass began at. loop_len is the song's length
	// rounded up to a whole bar, so the beat carries on across the seam.
	loop:      bool,
	loop_len:  int,
	loop_base: int,
}

// Flatten `song` from `from_tick` onwards. Notes already sounding at
// `from_tick` are started, shortened, so starting mid-phrase is not silent.
engine_start :: proc(e: ^Engine, song: ^Song, from_tick: i32 = 0, mode := DEFAULT_MODE) {
	engine_destroy(e)
	e.mode = mode
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

	// One pass: from `from_tick` to the end of the last note's bar.
	bt := bar_ticks(song)
	end := (song_end_tick(song) + bt - 1) / bt * bt
	e.loop_len = int(f64(max(end - from_tick, 0)) * spt * SAMPLE_RATE)
}

// Keep playing from the start (well: from `from_tick`) when the end is
// reached. A song with no notes never loops.
engine_set_loop :: proc(e: ^Engine, loop: bool) {
	e.loop = loop && e.loop_len > 0 && len(e.events) > 0
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

// Is there anything left to play? Never true while looping.
engine_done :: proc(e: ^Engine) -> bool {
	if e.loop do return false
	return e.next >= len(e.events) && len(e.voices) == 0
}

// Where playback is, in seconds since engine_start (counting every pass of a
// loop), and within the current pass.
engine_time :: proc(e: ^Engine) -> (total, in_pass: f64) {
	return f64(e.frame) / SAMPLE_RATE, f64(e.frame - e.loop_base) / SAMPLE_RATE
}

// Fill `out` (stereo, interleaved) with the next block. Returns false once the
// song has completely finished ringing. The finished mix: master level
// applied and clamped, ready for a speaker.
engine_render :: proc(e: ^Engine, out: []f32) -> bool {
	slice.fill(out, 0)
	more := engine_render_add(e, out)
	for &s in out do s = clamp(s * MASTER, -1, 1)
	return more
}

// The raw version for mixing: ADDS the next block into `out`, before the
// master level and the clamp. The Mixer uses this to put several songs and the
// sound effects together first.
engine_render_add :: proc(e: ^Engine, out: []f32) -> bool {
	frames := len(out) / 2
	block_end := e.frame + frames

	for {
		if e.next >= len(e.events) {
			// End of a pass: start the next one, if looping and it begins in
			// this block.
			if !e.loop || e.loop_base + e.loop_len >= block_end do break
			e.loop_base += e.loop_len
			e.next = 0
			continue
		}
		ev := e.events[e.next]
		if ev.start + e.loop_base >= block_end do break
		v := voice_make(ev, e.insts[ev.inst], e.mode) // seeded from the pass-relative start
		v.ev.start += e.loop_base
		append(&e.voices, v)
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
			done = voice_render(v, out[offset * 2:], g0, g1, frames, offset)
		}
		if done do unordered_remove(&e.voices, i)
	}
	for &g, i in e.gain do g = e.target[i]
	e.frame = block_end
	return !engine_done(e)
}

// Render a whole song into one buffer: export and the render tool.
render_song :: proc(song: ^Song, mode := DEFAULT_MODE, allocator := context.allocator) -> []f32 {
	e: Engine
	engine_start(&e, song, 0, mode)
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
render_preview :: proc(ins: Instrument, p: Pitch, seconds: f32 = 0.35, mode := DEFAULT_MODE, allocator := context.allocator) -> []f32 {
	ev := Event {
		gate = int(seconds * RATE),
		midi = f32(pitch_midi(p)),
		amp  = 0.8 * ins.gain,
		pan  = 0,
	}
	v := voice_make(ev, ins, mode)
	out := make([]f32, v.life * 2, allocator)
	voice_render(&v, out, 1, 1, 1, 0)
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
voice_make :: proc(ev: Event, ins: Instrument, mode: Sound_Mode) -> Voice {
	v := Voice {
		ev    = ev,
		ins   = ins,
		// Not 1, as the NES powered up with: from 1 the register spends its
		// first few hundred steps mostly low, and a short drum hit made of
		// them is lopsided (a DC offset, a thump in the speaker). Both of
		// these are well mixed, and in metallic mode sit on a balanced
		// 93-step loop (seed 1 there loops on a very lopsided one).
		lfsr  = LFSR_SEED,
		lfsr2 = 0x5A5A,
		freq  = midi_freq(ev.midi),
		white = 0x9E3779B9 ~ u32(ev.start) * 2654435761 ~ u32(ev.track) * 40503 ~ u32(ev.midi * 8),
	}
	if v.white == 0 do v.white = 1
	v.life = ev.gate + int(max(ins.release, 0.005) * RATE)
	// A struck or plucked note rings for its decay whatever its written
	// length, as a harp string does.
	if ins.sustain <= 0 do v.life = max(v.life, int((ins.attack + ins.decay) * RATE))
	v.mode = mode

	if mode >= .Bit16 {
		// A player is never exactly in tune, and never quite regular: a few
		// cents either way, and vibrato a little faster or slower, wider or
		// narrower, note to note. Seeded from the note, so it is the same
		// every time the song is played.
		h := hash_u32(v.white)
		detune := (unit(h) * 2 - 1) * 4 // cents
		v.freq *= math.pow(2, detune / 1200)
		h = hash_u32(h)
		v.vib_k[0] = 1 + (unit(h) * 2 - 1) * 0.08
		h = hash_u32(h)
		v.vib_k[1] = 1 + (unit(h) * 2 - 1) * 0.2
		h = hash_u32(h)
		v.wander = {unit(h) * TAU, unit(hash_u32(h)) * TAU}
	}
	if mode == .Bit32 {
		if ins.model == .Bowed {
			bowed_init(&v.bow, &v.ins, v.freq)
			// A bowed string rings on after the bow leaves it: give it time
			// to die away instead of being cut off.
			v.life = ev.gate + int(max(ins.release * 3, 0.3) * RATE)
		}
		for k in 0 ..< int(ins.n_resonances) do v.body[k] = biquad_peak(ins.resonances[k])
	}
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
osc :: #force_inline proc(w: Wave, ph, dt, duty: f32, noise_out: f32, smooth := false) -> f32 {
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
		if smooth do return tri
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

LFSR_SEED :: 0x4A3B

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
voice_render :: proc(v: ^Voice, out: []f32, g0, g1: f32, ramp_len, ramp_at: int) -> bool {
	ins := &v.ins
	frames := len(out) / 2
	gate := f32(v.ev.gate) / RATE
	ratio2 := math.pow(2, ins.semis2 / 12)
	f := v.f_now if v.f_now > 0 else v.freq
	defer v.f_now = f
	for i in 0 ..< frames {
		if v.age >= v.life do return true
		t := f32(v.age) / RATE

		if v.age % CONTROL_FRAMES == 0 {
			semis: f32 = 0
			human := v.mode >= .Bit16
			if ins.vib_depth > 0 && t > ins.vib_delay {
				fade_in := min((t - ins.vib_delay) / 0.25, 1)
				rate, depth := ins.vib_rate, ins.vib_depth
				if human {rate *= v.vib_k[0]; depth *= v.vib_k[1]}
				semis += depth * fade_in * math.sin(TAU * rate * (t - ins.vib_delay))
			}
			if human && ins.vib_depth > 0 {
				// A slow wander under the vibrato: two slow sines that never
				// line up, a few cents deep.
				semis += 0.03 * math.sin(TAU * 0.73 * t + v.wander[0]) + 0.02 * math.sin(TAU * 1.91 * t + v.wander[1])
			}
			if ins.sweep != 0 do semis += ins.sweep * math.exp(-t / max(ins.sweep_time, 1e-3))
			f = v.freq * math.pow(2, semis / 12)
		}

		dt := f / RATE
		dt2 := dt * ratio2

		// Noise is clocked by the pitch: higher rows, brighter hiss.
		bowed := v.mode == .Bit32 && ins.model == .Bowed
		noise: f32 = 0
		if ins.breath > 0 {
			v.white ~= v.white << 13
			v.white ~= v.white >> 17
			v.white ~= v.white << 5
			noise = f32(v.white) / f32(max(u32)) * 2 - 1
		}
		env := envelope(ins, t, gate)
		if v.mode == .Bit4 do env = math.round(env * 15) / 15

		x: f32
		if bowed {
			if v.age % CONTROL_FRAMES == 0 do bowed_tune(&v.bow, f)
			// The envelope is the bow: how fast it is drawn. The string
			// makes the sound, and rings on for a moment after the bow lifts;
			// that ring is faded out by the end of the voice's life.
			x = bowed_tick(&v.bow, env, noise * ins.breath)
			if t > gate {
				tail := max(ins.release * 3, 0.3)
				x *= max(1 - (t - gate) / tail, 0)
			}
		} else {
			// Noise is clocked by the pitch: higher rows, brighter hiss.
			if ins.wave == .Noise {
				v.nclock += dt * 8
				for v.nclock >= 1 {v.nclock -= 1; v.nout = lfsr_step(&v.lfsr, ins.metallic)}
			}
			if ins.mix2 > 0 && ins.wave2 == .Noise {
				v.nclock2 += dt2 * 8
				for v.nclock2 >= 1 {v.nclock2 -= 1; v.nout2 = lfsr_step(&v.lfsr2, ins.metallic)}
			}
			smooth := v.mode >= .Bit16
			sig := osc(ins.wave, v.phase, dt, ins.duty, v.nout, smooth)
			if ins.mix2 > 0 {
				sig = sig * (1 - ins.mix2) + osc(ins.wave2, v.phase2, dt2, ins.duty, v.nout2, smooth) * ins.mix2
			}
			if ins.breath > 0 {
				// From 16-bit: a burst of it as the note starts - the scratch
				// of the bow biting, the chiff of a flute - dying in ~35 ms.
				chiff: f32 = smooth ? 1 + 6 * math.exp(-t / 0.035) : 1
				sig += ins.breath * noise * chiff
			}
			v.phase = fract(v.phase + dt)
			v.phase2 = fract(v.phase2 + dt2)

			// The muffle from sounds_example: one pole, 1 = open.
			v.lp += clamp(ins.tone, 0.01, 1) * (sig - v.lp)
			x = v.lp * env
		}
		// 32-bit: the body the string (or reed, or pipe) sits in.
		if v.mode == .Bit32 {
			for k in 0 ..< int(ins.n_resonances) do x = biquad_tick(&v.body[k], x)
		}

		a := x * v.ev.amp
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
