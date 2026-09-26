package music

/*
    Pitch detection: what note is being played into a microphone.

    Used by the editor's input mode (mic.odin in the app): the samples come in
    from the mic, a few hundred at a time; every HOP samples this looks at the
    last stretch of sound and says which note it holds, if any.

    THREE STAGES.

    1. Filtering. A band-pass around the notes the instrument can play: a
       steep high-pass below its lowest note (rumble, traffic, the hum of the
       mains, a desk being knocked) and a low-pass above the top of its
       range (hiss, clatter, the "s" of someone talking). Both follow the
       range, so a cello's are not a piccolo's.

    2. The noise gate. The level of the room is learned as it goes, from
       everything that is not a note: it falls at once to anything quieter,
       and rises over a few seconds - so a fan, a fridge or a computer's hum
       is learned and then ignored, while a note, however long it is held or
       however slowly the bow brings it in, never is. A note counts only when
       it is `sensitivity` times the room's level (2 by default: 6 dB above
       it), and stops counting a little below that, so a note does not
       flicker as it fades. Higher sensitivity numbers ignore more: a quiet
       radio, a neighbour practising.

    3. YIN (de Cheveigne and Kawahara, 2002). For each lag tau, how different
       the sound is from itself tau samples later; a periodic sound is least
       different at its period. The difference is normalised by its own
       running average, the first dip below THRESHOLD is taken (the first, so
       a note is not read an octave low), and a parabola through the dip and
       its neighbours gives the period to a fraction of a sample. Lags are
       searched only within the instrument's range and a whole tone past each
       end. How deep the dip is doubles as a confidence: noise has no dip
       worth the name, and is rejected here even when it is loud.

    Then the median of the last three readings, so one stray reading (a bow
    change, a squeak) never reaches the screen.

    Readings carry how long ago the sound they describe was heard (the middle
    of the stretch analysed, and the median's one-reading lag), so the caller
    can put them at the right place in time.
*/

import "core:math"

PITCH_RATE :: 22050 // what the mic is opened at: plenty for a note's pitch
PITCH_RING :: 4096
PITCH_WIN_MAX :: 1024
PITCH_TAU_MAX :: 560 // the longest period searched: ~39 Hz, below a bass's low E
PITCH_THRESHOLD :: f32(0.15)
PITCH_REJECT :: f32(0.3) // no dip below this at all: not a note
PITCH_ABS_MIN :: f32(0.002) // below this level (-54 dBFS) it is never a note
PITCH_SENSITIVITY_DEFAULT :: f32(2)

Pitch_Reading :: struct {
	midi:  f32, // 0 = nothing being played
	level: f32, // RMS, 0..1
	delay: int, // samples between the sound described and the end of the feed
}

Pitch_Detector :: struct {
	// Settings: the notes to look for (the instrument's range) and the gate.
	lo, hi:      f32,
	sensitivity: f32,
	// The filters, for the range they were made for.
	f_lo, f_hi:  f32,
	hp:          [2]Biquad,
	lp:          Biquad,
	ring:        [PITCH_RING]f32,
	w:           int,
	filled:      int,
	fresh:       int, // samples since the last analysis
	floor:       f32,
	open:        bool, // the gate
	level:       f32,
	hist:        [3]f32,
	hist_n:      int,
	// The latest (smoothed) reading.
	midi:        f32,
	clarity:     f32, // 1 - the dip: 1 = a pure tone, 0 = noise
	analyses:    u64,
	// Scratch, kept here so nothing is on the stack.
	buf:         [PITCH_WIN_MAX + PITCH_TAU_MAX + 1]f32,
	diff:        [PITCH_TAU_MAX + 2]f32,
}

pitch_init :: proc(d: ^Pitch_Detector, lo_midi, hi_midi: f32) {
	d^ = {}
	d.sensitivity = PITCH_SENSITIVITY_DEFAULT
	pitch_set_range(d, lo_midi, hi_midi)
}

// Look for notes from lo to hi (MIDI numbers). Cheap if nothing changed.
pitch_set_range :: proc(d: ^Pitch_Detector, lo_midi, hi_midi: f32) {
	lo := max(lo_midi - 2, midi_of(f32(PITCH_RATE) / PITCH_TAU_MAX) + 0.1)
	hi := min(hi_midi + 2, midi_of(f32(PITCH_RATE) / 4))
	if lo == d.lo && hi == d.hi do return
	d.lo, d.hi = lo, hi
	// High-pass a fifth or so below the lowest note, two of them in a row
	// for a steep cut; low-pass a little above the top note's second
	// harmonic (the fundamental is what is measured; that much above keeps
	// its shape).
	f_lo := clamp(midi_freq(lo) * 0.7, 25, 400)
	f_hi := clamp(midi_freq(hi) * 2.2, 1000, f32(PITCH_RATE) * 0.42)
	if f_lo != d.f_lo || f_hi != d.f_hi {
		d.f_lo, d.f_hi = f_lo, f_hi
		d.hp[0] = biquad_pass(f_lo, 0.54, true)
		d.hp[1] = biquad_pass(f_lo, 1.31, true) // 4th-order Butterworth, as two
		d.lp = biquad_pass(f_hi, 0.707, false)
	}
}

// Feed samples (mono, PITCH_RATE, -1..1). Readings made along the way go
// into `out`; returns how many.
pitch_feed :: proc(d: ^Pitch_Detector, samples: []f32, out: []Pitch_Reading) -> int #no_bounds_check {
	n := 0
	hop := pitch_hop(d)
	for s, i in samples {
		x := biquad_tick(&d.hp[0], s)
		x = biquad_tick(&d.hp[1], x)
		x = biquad_tick(&d.lp, x)
		d.ring[d.w] = x
		d.w = (d.w + 1) % PITCH_RING
		d.filled = min(d.filled + 1, PITCH_RING)
		d.fresh += 1
		if d.fresh >= hop && n < len(out) {
			d.fresh = 0
			r := pitch_analyse(d)
			r.delay += len(samples) - 1 - i
			out[n] = r
			n += 1
		}
	}
	return n
}

// How often to look: every 256 samples (12 ms), or 512 when the range
// reaches so low that each look is expensive.
@(private)
pitch_hop :: proc(d: ^Pitch_Detector) -> int {
	tau_max, w := pitch_span(d)
	return tau_max * w > 400_000 ? 512 : 256
}

// The longest period searched, and how much sound is compared: two of the
// longest periods (and at least 256 samples).
@(private)
pitch_span :: proc(d: ^Pitch_Detector) -> (tau_max, w: int) {
	tau_max = clamp(int(f32(PITCH_RATE) / midi_freq(d.lo)) + 2, 8, PITCH_TAU_MAX)
	w = clamp(2 * tau_max, 256, PITCH_WIN_MAX)
	return
}

@(private)
pitch_analyse :: proc(d: ^Pitch_Detector) -> Pitch_Reading #no_bounds_check {
	d.analyses += 1
	tau_max, W := pitch_span(d)
	tau_min := max(int(f32(PITCH_RATE) / midi_freq(d.hi)) - 1, 2)
	total := W + tau_max
	r := Pitch_Reading{delay = total / 2 + pitch_hop(d)}
	if d.filled < total do return r

	// The last `total` samples, oldest first.
	start := (d.w - total + PITCH_RING) % PITCH_RING
	for k in 0 ..< total do d.buf[k] = d.ring[(start + k) % PITCH_RING]

	// The level of the newest stretch.
	sum: f32
	for k in total - W ..< total do sum += d.buf[k] * d.buf[k]
	level := math.sqrt(sum / f32(W))
	d.level = level
	r.level = level

	// Is it a note at all? (YIN, below: noise has no period.)
	raw: f32
	if level > PITCH_ABS_MIN do raw = pitch_yin(d, W, tau_min, tau_max)

	// The room's level: learned only from what is not a note, so a note
	// that swells in slowly (a bow's attack) or is held for a long time is
	// never taken for the room. Down at once, up over a few seconds.
	if d.floor <= 0 do d.floor = level
	if raw == 0 {
		rate: f32 = level < d.floor ? 0.3 : 0.005
		d.floor += (level - d.floor) * rate
	}
	d.floor = max(d.floor, 0.00005)
	// The gate: a note must stand above the room.
	thr := max(d.floor * d.sensitivity, PITCH_ABS_MIN)
	d.open = level > (d.open ? thr * 0.6 : thr)
	if !d.open do raw = 0

	// The median of the last three (silence counts as 0: two silent of three
	// is silence).
	d.hist[0], d.hist[1] = d.hist[1], d.hist[2]
	d.hist[2] = raw
	d.hist_n = min(d.hist_n + 1, 3)
	a, b, c := d.hist[0], d.hist[1], d.hist[2]
	med := max(min(a, b), min(max(a, b), c))
	if d.hist_n < 3 do med = raw
	// Median of values mixing notes a semitone apart can land between them;
	// that is fine - it is one of the readings.
	d.midi = med
	r.midi = med
	return r
}

// The period, by YIN; returned as a MIDI note (fractional), 0 for none.
@(private)
pitch_yin :: proc(d: ^Pitch_Detector, W, tau_min, tau_max: int) -> f32 #no_bounds_check {
	x := d.buf[:]
	// Difference function.
	for tau in 1 ..= tau_max {
		s: f32
		for j in 0 ..< W {
			v := x[j] - x[j + tau]
			s += v * v
		}
		d.diff[tau] = s
	}
	// Cumulative mean normalised.
	d.diff[0] = 1
	run: f32
	for tau in 1 ..= tau_max {
		run += d.diff[tau]
		d.diff[tau] = run > 0 ? d.diff[tau] * f32(tau) / run : 1
	}
	// The first dip below the threshold, followed down to its bottom...
	best := -1
	for tau in tau_min ..= tau_max {
		if d.diff[tau] < PITCH_THRESHOLD {
			t := tau
			for t + 1 <= tau_max && d.diff[t + 1] < d.diff[t] do t += 1
			best = t
			break
		}
	}
	// ...or, failing that, the deepest dip, if it is a dip at all.
	if best < 0 {
		lowest := f32(1e9)
		for tau in tau_min ..= tau_max {
			if d.diff[tau] < lowest {lowest = d.diff[tau]; best = tau}
		}
		if lowest > PITCH_REJECT do best = -1
	}
	if best < 0 {
		d.clarity = 0
		return 0
	}
	d.clarity = 1 - d.diff[best]
	// A parabola through the bottom and its neighbours.
	period := f32(best)
	if best > 1 && best < tau_max {
		s0, s1, s2 := d.diff[best - 1], d.diff[best], d.diff[best + 1]
		den := s0 + s2 - 2 * s1
		if den != 0 do period += clamp(0.5 * (s0 - s2) / den, -1, 1)
	}
	m := midi_of(f32(PITCH_RATE) / period)
	if m < d.lo - 0.5 || m > d.hi + 0.5 do return 0
	return m
}

// Frequency to MIDI note number (fractional).
midi_of :: proc(freq: f32) -> f32 {
	return 69 + 12 * math.log2(max(freq, 1) / 440)
}

// A 2nd-order high-pass or low-pass (the Audio EQ Cookbook's), at PITCH_RATE.
@(private)
biquad_pass :: proc(f, q: f32, high: bool) -> Biquad {
	w0 := TAU * f / f32(PITCH_RATE)
	alpha := math.sin(w0) / (2 * q)
	c := math.cos(w0)
	a0 := 1 + alpha
	if high {
		return Biquad{b0 = (1 + c) / 2 / a0, b1 = -(1 + c) / a0, b2 = (1 + c) / 2 / a0, a1 = -2 * c / a0, a2 = (1 - alpha) / a0}
	}
	return Biquad{b0 = (1 - c) / 2 / a0, b1 = (1 - c) / a0, b2 = (1 - c) / 2 / a0, a1 = -2 * c / a0, a2 = (1 - alpha) / a0}
}
