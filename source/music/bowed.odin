package music

/*
    32-bit mode's two extras: a bowed string, simulated, and the body it is
    mounted on.

    THE BOWED STRING. Not a waveform: a model of what a bow does to a string.
    The string is two delay lines, one each side of the bow - bow to nut,
    bow to bridge - carrying the wave that runs up and down it. Where they
    meet, the bow grips the string and drags it along, until the string's own
    pull tears it free; it slips back, is caught again, and so on - stick,
    slip, stick, slip, once per vibration. That friction is a single curve
    (bow_friction): high grip when string and bow move together, falling away
    as they move apart. The bridge end loses a little of the wave each trip
    (a one-pole filter), which is where the string's tone and its decay come
    from.

    The design is the classic one: McIntyre, Schumacher and Woodhouse (1983),
    as Perry Cook and Gary Scavone wrote it for the Synthesis ToolKit (STK's
    Bowed class). What comes out has the things a saw wave cannot: the grain
    of the bow, a start that has to catch before it speaks, a note that rings
    after the bow lifts.

    In an instrument file:

        model bowed 0.5 0.13      # pressure 0..1 (default 0.5), bow position:
                                  # the fraction of the string from the bridge
                                  # (default 0.127; smaller = brighter, glassier)

    THE BODY. A violin family instrument's box amplifies some frequencies and
    swallows others, and those peaks are most of what makes a cello sound like
    a cello and not a violin played low. Each is a `resonance` line: a peaking
    filter at a frequency, with a width (Q) and a boost in dB (negative cuts).
    Any instrument can have up to four; they are heard in 32-bit mode only.

        resonance 105 3 5         # the air in the box
        resonance 190 4 4         # the main wood resonance
        resonance 2200 1.5 3      # the bridge
*/

import "core:math"

MAX_RESONANCES :: 4

Model :: enum u8 {
	None,
	Bowed,
}

Resonance :: struct {
	freq, q, gain_db: f32,
}

// ---------------------------------------------------------------------------
// The bowed string
// ---------------------------------------------------------------------------

@(private)
BOW_LINE :: 1024 // each delay line; the lowest note it can play is ~37 Hz

Bowed :: struct {
	neck:     [BOW_LINE]f32,
	bridge:   [BOW_LINE]f32,
	w:        int, // where both lines write next
	neck_d:   f32, // delays, in samples
	bridge_d: f32,
	lp:       f32, // the bridge's loss filter
	slope:    f32, // the friction curve's steepness: bow pressure
	beta:     f32, // bow position
	max_vel:  f32,
	gain:     f32, // output level: high notes speak more quietly in the model
}

// Loop-delay allowance for the loss filter and the read-before-write, so
// the string sounds at the pitch asked for. Measured, see tools/render.
@(private)
BOW_COMP :: f32(1.6)

bowed_init :: proc(b: ^Bowed, ins: ^Instrument, freq: f32) {
	b^ = {}
	pressure := ins.bow_pressure
	b.slope = 5 - 4 * clamp(pressure, 0, 1)
	b.beta = clamp(ins.bow_position, 0.02, 0.5)
	// Drawn gently: at this speed the string settles into clean Helmholtz
	// motion (a sawtooth, as a real bowed string) across the whole range;
	// much faster and it breaks into octave squeaks.
	b.max_vel = 0.08
	bowed_tune(b, freq)
}

// Set the pitch (vibrato and slides call this as they go).
bowed_tune :: proc(b: ^Bowed, freq: f32) {
	f := max(freq, 20)
	// The loop has a little more delay in it than the two lines (the loss
	// filter, the read-before-write): measured, it is 1.6 samples at 440 Hz
	// and below, falling to 1.4 by 2400 Hz.
	comp := BOW_COMP - 0.2 * clamp(math.log2(f / 440) / 2.45, 0, 1)
	total := clamp(RATE / f - comp, 4, f32(BOW_LINE) * 1.9)
	// High up, a player bows nearer the bridge; in the model, the bridge
	// side needs a few samples of string or it stops speaking at all.
	b.bridge_d = clamp(max(total * b.beta, min(4.2, total * 0.35)), 1, f32(BOW_LINE - 2))
	b.neck_d = clamp(total - b.bridge_d, 1, f32(BOW_LINE - 2))
	// ...and above ~440 Hz the model gets quieter than a player would: make
	// up for it.
	b.gain = BOW_OUT * min(math.sqrt(max(f / 440, 1)), 3)
}

// One sample. `bow` 0..1 is how hard the bow is being drawn (the envelope);
// `grit` a little noise on its speed: rosin.
bowed_tick :: #force_inline proc(b: ^Bowed, bow, grit: f32) -> f32 #no_bounds_check {
	read :: #force_inline proc(line: ^[BOW_LINE]f32, w: int, d: f32) -> f32 {
		pos := f32(w) - d
		for pos < 0 do pos += BOW_LINE
		i := int(pos)
		frac := pos - f32(i)
		if i >= BOW_LINE do i -= BOW_LINE
		j := i + 1 >= BOW_LINE ? 0 : i + 1
		return line[i] * (1 - frac) + line[j] * frac
	}
	bridge_out := read(&b.bridge, b.w, b.bridge_d)
	neck_out := read(&b.neck, b.w, b.neck_d)

	// The bridge: a little of the wave lost each trip, the high end most.
	b.lp = 0.95 * (bridge_out * (1 - BOW_POLE)) + BOW_POLE * b.lp
	bridge_refl := -b.lp
	nut_refl := -neck_out

	string_vel := bridge_refl + nut_refl
	bow_vel := b.max_vel * bow * (1 + grit)
	dv := bow_vel - string_vel
	nv := dv * bow_friction(dv, b.slope)

	b.neck[b.w] = bridge_refl + nv
	b.bridge[b.w] = nut_refl + nv
	b.w += 1
	if b.w >= BOW_LINE do b.w = 0
	return bridge_out * b.gain
}

@(private)
BOW_POLE :: f32(0.75 - 0.2 * 22050.0 / SAMPLE_RATE)

// Output level, so a bowed cello sits where the chip cello did in the mix.
@(private)
BOW_OUT :: f32(3.6)

// How firmly the bow holds the string, by how fast they move against each
// other: 1 = stuck together, falling toward 0 as they slide.
@(private)
bow_friction :: #force_inline proc(dv, slope: f32) -> f32 {
	x := abs((dv + 0.001) * slope) + 0.75
	x2 := x * x
	return clamp(1 / (x2 * x2), 0.01, 0.98)
}

// ---------------------------------------------------------------------------
// The body: peaking filters (the Audio EQ Cookbook's)
// ---------------------------------------------------------------------------

Biquad :: struct {
	b0, b1, b2, a1, a2: f32,
	x1, x2, y1, y2:     f32,
}

biquad_peak :: proc(r: Resonance) -> Biquad {
	f := clamp(r.freq, 20, RATE * 0.45)
	q := max(r.q, 0.1)
	A := math.pow(10, r.gain_db / 40)
	w0 := TAU * f / RATE
	alpha := math.sin(w0) / (2 * q)
	c := math.cos(w0)
	a0 := 1 + alpha / A
	return Biquad {
		b0 = (1 + alpha * A) / a0,
		b1 = (-2 * c) / a0,
		b2 = (1 - alpha * A) / a0,
		a1 = (-2 * c) / a0,
		a2 = (1 - alpha / A) / a0,
	}
}

biquad_tick :: #force_inline proc(q: ^Biquad, x: f32) -> f32 {
	y := q.b0 * x + q.b1 * q.x1 + q.b2 * q.x2 - q.a1 * q.y1 - q.a2 * q.y2
	q.x2, q.x1 = q.x1, x
	q.y2, q.y1 = q.y1, y
	return y
}

// ---------------------------------------------------------------------------

// A cheap, good-enough hash for per-note randomness.
hash_u32 :: proc(x: u32) -> u32 {
	h := x
	h ~= h >> 16
	h *= 0x7feb352d
	h ~= h >> 15
	h *= 0x846ca68b
	h ~= h >> 16
	return h
}

// 0..1
unit :: proc(h: u32) -> f32 {
	return f32(h >> 8) / f32(1 << 24)
}
