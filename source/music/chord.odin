package music

/*
    Chord detection: which notes - one, two, three or more - are sounding in
    what a microphone hears. The input mode's "open detection" (input.odin in
    the app); pitch.odin's YIN finds one note, this finds several.

    Every CHORD_HOP samples (12 ms) the last stretch of sound (186 ms when the
    range goes down to the cello's low notes, 93 ms above that: long enough
    to tell C2 from C#2, which are 4 Hz apart) goes through five steps:

    1. SPECTRUM. A Hann window and an FFT: how much of every frequency there
       is. The same band-pass as pitch.odin in front, so rumble and hiss never
       get this far.

    2. THE ROOM. The spectrum of the room - fan, hum, traffic - is learned
       from every frame in which no note is found (quickly down, slowly up)
       and taken away twice over, so a steady noise leaves nothing behind.
       The loudness gate of pitch.odin decides whether anything is being
       played at all. What is left is square-rooted, so a note's weak upper
       partials count for something next to its strong low ones.

    3. SALIENCE. For every candidate note in the instrument's range (every
       fifth of a semitone), add up what is found at its harmonics - 1, 2, 3
       ... times its frequency, a quarter tone either way - the lower
       harmonics weighing more (Klapuri's weights, 2006). A note that is being
       played collects from all its harmonics; a note an octave or a fifth
       away collects from only some of them, and noise from none in
       particular.

    4. ONE NOTE AT A TIME. The strongest candidate is taken, its frequency
       refined from where its harmonics' peaks really are (so its cents are
       right), and its harmonics are taken out of the spectrum - but only as
       much as a smooth run of harmonics would have: where a partial stands
       taller than its neighbours, another note shares it (C3 and C4 share
       every harmonic of C4), and what stands above the smooth line is left
       for that note. Then again, for the next note, while it is at least
       CHORD_REL of the first one's strength, up to max_notes.

    5. STEADINESS. A note is reported once it has been found in two frames
       running, and kept until it has been missing for three: no flicker at
       a bow change, no one-frame ghosts.

    Each reading also says, for every semitone of the range, how strongly it
    is present and how many cents off (from step 3, before anything was taken
    out): the Check mode's evidence that an expected note was played, even
    when step 4 would not have counted it on its own.

    Cost: an FFT of 4096 and a few hundred candidates of 14 harmonics, up to
    max_notes + 1 times - a fraction of a millisecond a frame optimised.
    tools/chord_test measures it and scores it on rendered chords in a noisy
    room.
*/

import "core:math"
import "core:slice"

CHORD_N_MAX :: 4096
CHORD_HOP :: 256
CHORD_MAX_NOTES :: 6
CHORD_H :: 14 // harmonics looked at
CHORD_TOP_HZ :: f32(5000) // ...up to here
CHORD_STEP :: f32(0.2) // semitones between candidates
CHORD_GRID_MAX :: 600
CHORD_SPAN :: 100 // semitones reported in presence[]
CHORD_REL :: f32(0.3) // a further note must be this strong next to the first
CHORD_REL_HARMONIC :: f32(0.55) // ...or this, an octave or a twelfth above one found
CHORD_PEAK :: f32(1.3) // ...and the first this much above the candidates' average
CHORD_TRACKS :: 12
CHORD_WIDTH :: f32(0.015) // how far from a harmonic's place a peak is looked for

Chord_Reading :: struct {
	notes:    [CHORD_MAX_NOTES]f32, // MIDI, fractional, low to high
	n:        int,
	level:    f32,
	delay:    int, // samples between the sound described and the end of the feed
	// Every semitone from `base`: how present it is (0..255, 255 = as
	// strong as the strongest note) and its best cents offset (-60..60).
	base:     int,
	presence: [CHORD_SPAN]u8,
	cents:    [CHORD_SPAN]i8,
}

@(private)
Chord_Track :: struct {
	midi:   f32,
	hits:   i8,
	misses: i8,
	on:     bool,
	used:   bool,
	seen:   bool, // matched this frame
}

Chord_Detector :: struct {
	lo, hi:      f32,
	sensitivity: f32,
	max_notes:   int,
	// One note only (chord_single): the note being played, not the chord
	// its own overtones can look like.
	single:      bool,
	f_lo, f_hi:  f32,
	hp:          [2]Biquad,
	lp:          Biquad,
	n:           int, // FFT size in use
	table_n:     int, // ...and the tables were made for
	ring:        [CHORD_N_MAX]f32,
	w:           int,
	filled:      int,
	fresh:       int,
	floor:       f32,
	open:        bool,
	level:       f32,
	noise:       [CHORD_N_MAX / 2]f32,
	noise_ready: bool,
	tracks:      [CHORD_TRACKS]Chord_Track,
	analyses:    u64,
	// Scratch.
	re, im:      [CHORD_N_MAX]f32,
	mag:         [CHORD_N_MAX / 2]f32,
	spec:        [CHORD_N_MAX / 2]f32,
	window:      [CHORD_N_MAX]f32,
	cos_t:       [CHORD_N_MAX / 2]f32,
	sin_t:       [CHORD_N_MAX / 2]f32,
	sal:         [CHORD_GRID_MAX]f32,
	sal0:        [CHORD_GRID_MAX]f32,
}

chord_init :: proc(d: ^Chord_Detector, lo_midi, hi_midi: f32) {
	d^ = {}
	d.sensitivity = PITCH_SENSITIVITY_DEFAULT
	d.max_notes = 4
	chord_set_range(d, lo_midi, hi_midi)
}

chord_set_range :: proc(d: ^Chord_Detector, lo_midi, hi_midi: f32) {
	lo := max(lo_midi - 1, 24)
	hi := min(hi_midi + 1, 110)
	if lo == d.lo && hi == d.hi do return
	d.lo, d.hi = lo, hi
	// Long enough to part the lowest notes' harmonics: 186 ms below ~F#3.
	d.n = midi_freq(lo) < 180 ? 4096 : 2048
	f_lo := clamp(midi_freq(lo) * 0.7, 25, 400)
	f_hi := min(CHORD_TOP_HZ, f32(PITCH_RATE) * 0.42)
	d.f_lo, d.f_hi = f_lo, f_hi
	d.hp[0] = biquad_pass(f_lo, 0.54, true)
	d.hp[1] = biquad_pass(f_lo, 1.31, true)
	d.lp = biquad_pass(f_hi, 0.707, false)
	if d.table_n != d.n {
		d.table_n = d.n
		for k in 0 ..< d.n {
			d.window[k] = 0.5 - 0.5 * math.cos(TAU * f32(k) / f32(d.n - 1))
		}
		for k in 0 ..< d.n / 2 {
			d.cos_t[k] = math.cos(TAU * f32(k) / f32(d.n))
			d.sin_t[k] = math.sin(TAU * f32(k) / f32(d.n))
		}
		d.noise_ready = false
	}
}

// Feed samples (mono, PITCH_RATE, -1..1); readings made along the way go
// into `out`. Returns how many.
chord_feed :: proc(d: ^Chord_Detector, samples: []f32, out: []Chord_Reading) -> int #no_bounds_check {
	n := 0
	for s, i in samples {
		x := biquad_tick(&d.hp[0], s)
		x = biquad_tick(&d.hp[1], x)
		x = biquad_tick(&d.lp, x)
		d.ring[d.w] = x
		d.w = (d.w + 1) % CHORD_N_MAX
		d.filled = min(d.filled + 1, CHORD_N_MAX)
		d.fresh += 1
		if d.fresh >= CHORD_HOP && n < len(out) {
			d.fresh = 0
			chord_analyse(d, &out[n])
			out[n].delay += len(samples) - 1 - i
			n += 1
		}
	}
	return n
}

// The latest notes found (what the last reading reported).
chord_notes :: proc(d: ^Chord_Detector, out: []f32) -> int {
	k := 0
	for t in d.tracks do if t.used && t.on && k < len(out) {out[k] = t.midi; k += 1}
	slice.sort(out[:k])
	return k
}

@(private)
chord_analyse :: proc(d: ^Chord_Detector, r: ^Chord_Reading) #no_bounds_check {
	d.analyses += 1
	N := d.n
	r^ = {}
	r.delay = N / 2 + CHORD_HOP
	r.base = int(d.lo)
	if d.filled < N do return

	// 1. The spectrum.
	start := (d.w - N + CHORD_N_MAX) % CHORD_N_MAX
	sum: f32
	for k in 0 ..< N {
		v := d.ring[(start + k) % CHORD_N_MAX]
		if k >= N / 2 do sum += v * v
		d.re[k] = v * d.window[k]
		d.im[k] = 0
	}
	level := math.sqrt(sum / f32(N / 2))
	d.level = level
	r.level = level
	fft(d.re[:N], d.im[:N], d.cos_t[:N / 2], d.sin_t[:N / 2])
	norm := 4 / f32(N) // a full-scale sine's peak comes out near 1
	half := N / 2
	for k in 0 ..< half {
		d.mag[k] = math.sqrt(d.re[k] * d.re[k] + d.im[k] * d.im[k]) * norm
	}

	// The gate, as pitch.odin's: the room's level, learned between notes.
	if d.floor <= 0 do d.floor = level
	thr := max(d.floor * d.sensitivity, PITCH_ABS_MIN)
	d.open = level > (d.open ? thr * 0.6 : thr)

	// 2. The room's spectrum, taken away.
	if !d.noise_ready {
		for k in 0 ..< half do d.noise[k] = d.mag[k]
		d.noise_ready = true
	}
	binw := f32(PITCH_RATE) / f32(N)
	k_top := min(int(CHORD_TOP_HZ / binw), half - 2)
	for k in 0 ..< half {
		v := k < k_top ? d.mag[k] - 2 * d.noise[k] : 0
		d.spec[k] = v > 0 ? math.sqrt(v) : 0
	}

	found: [CHORD_MAX_NOTES]f32
	n_found := 0
	if d.open {
		n_found = chord_find(d, found[:min(d.max_notes, CHORD_MAX_NOTES)], r)
		if d.single do n_found = chord_single(found[:n_found])
	}

	// Learn the room from what is not a note - and not loud: a note the
	// search missed for a moment must not be learned as the room.
	if n_found == 0 && level < thr * 1.5 {
		d.floor += (level - d.floor) * (level < d.floor ? 0.3 : 0.01)
		d.floor = max(d.floor, 0.00005)
		for k in 0 ..< half {
			m := d.mag[k]
			d.noise[k] += (m - d.noise[k]) * (m < d.noise[k] ? 0.3 : 0.03)
		}
	}

	// 5. Steadiness.
	for &t in d.tracks do t.seen = false
	for f in found[:n_found] {
		best := -1
		bd := f32(0.6)
		for &t, i in d.tracks {
			if !t.used || t.seen do continue
			if dd := abs(t.midi - f); dd < bd {bd = dd; best = i}
		}
		if best < 0 {
			for &t, i in d.tracks do if !t.used {best = i; d.tracks[i] = {}; break}
			if best < 0 do continue
			d.tracks[best].used = true
			d.tracks[best].midi = f
		}
		t := &d.tracks[best]
		t.seen = true
		t.midi = t.midi * 0.4 + f * 0.6
		t.hits = min(t.hits + 1, 10)
		t.misses = 0
		if t.hits >= 2 do t.on = true
	}
	for &t in d.tracks {
		if !t.used || t.seen do continue
		t.misses += 1
		t.hits = 0
		if t.misses >= (t.on ? 3 : 1) do t = {}
	}
	r.n = chord_notes(d, r.notes[:])
}

// Steps 3 and 4: find the notes, strongest first. Also fills the reading's
// presence (for the Check mode).
@(private)
chord_find :: proc(d: ^Chord_Detector, out: []f32, r: ^Chord_Reading) -> int #no_bounds_check {
	binw := f32(PITCH_RATE) / f32(d.n)
	count := min(int((d.hi - d.lo) / CHORD_STEP) + 1, CHORD_GRID_MAX)
	cand :: proc(d: ^Chord_Detector, i: int) -> f32 {return d.lo + f32(i) * CHORD_STEP}

	n := 0
	first: f32
	for iter in 0 ..= len(out) {
		for i in 0 ..< count do d.sal[i] = chord_salience(d, midi_freq(cand(d, i)), binw)
		if iter == 0 do copy(d.sal0[:count], d.sal[:count])
		if iter == len(out) do break
		// The strongest, away from notes already found.
		bi := -1
		bs := f32(0)
		for i in 0 ..< count {
			c := cand(d, i)
			near := false
			for f in out[:n] do if abs(f - c) < 0.9 do near = true
			if near do continue
			if d.sal[i] > bs {bs = d.sal[i]; bi = i}
		}
		if bi < 0 || bs <= 0 do break
		c := cand(d, bi)
		if n == 0 {
			// Is it a note at all: well above the candidates in general?
			mean: f32
			for i in 0 ..< count do mean += d.sal[i]
			mean /= f32(count)
			if bs < mean * CHORD_PEAK do break
			first = bs
		} else {
			// A note an octave or a twelfth above one already found lives on
			// that note's harmonics: what is left of those after it was taken
			// out is most of what it has, so it must show more to count.
			need := CHORD_REL
			for f in out[:n] {
				ratio := math.pow(2, (c - f) / 12)
				if ratio > 1.5 && abs(ratio - math.round(ratio)) < 0.04 do need = CHORD_REL_HARMONIC
			}
			if bs < first * need do break
		}
		f, ok := chord_refine(d, midi_freq(c), binw)
		m := midi_of(f)
		if !ok || m < d.lo - 0.5 || m > d.hi + 0.5 {
			// Nothing where its harmonics should be: not a note. Try the next.
			chord_cancel(d, midi_freq(c), binw)
			continue
		}
		out[n] = m
		n += 1
		chord_cancel(d, f, binw)
	}

	// Presence, for the Check mode: what is left of each semitone once the
	// notes found are taken out (d.sal is the last pass's, on that residue),
	// against the strongest note - so a note that was played but fell short
	// of CHORD_REL still shows, while one that only shares harmonics with a
	// note that was found does not. The notes found are fully present.
	if first <= 0 do for i in 0 ..< count do first = max(first, d.sal0[i])
	if first > 0 {
		for s in 0 ..< CHORD_SPAN {
			m := f32(r.base + s)
			if m < d.lo || m > d.hi do continue
			best := f32(0)
			at := f32(0)
			for i in 0 ..< count {
				c := cand(d, i)
				if abs(c - m) > 0.61 do continue
				if d.sal[i] > best {best = d.sal[i]; at = c - m}
			}
			r.presence[s] = u8(clamp(best / first, 0, 1) * 255)
			r.cents[s] = i8(clamp(at * 100, -60, 60))
		}
		for f in out[:n] {
			s := int(math.round(f)) - r.base
			if s < 0 || s >= CHORD_SPAN do continue
			r.presence[s] = 255
			r.cents[s] = i8(clamp((f - math.round(f)) * 100, -60, 60))
		}
	}
	return n
}

// Single-note mode: of the notes found, the one being played. A string
// with strong overtones (a cello's open C) can make its octave, twelfth or
// double octave strong enough to be found as notes of their own; what is
// played is then the lowest note of which the strongest is an overtone -
// the strongest itself, if it is no note's overtone. Leaves it in found[0];
// returns 1 (or 0).
chord_single :: proc(found: []f32) -> int {
	if len(found) == 0 do return 0
	strongest := found[0] // found strongest first
	root := strongest
	for f in found[1:] {
		if f < root && overtone_of(strongest, f) do root = f
	}
	found[0] = root
	return 1
}

// Is `hi` (MIDI) the 2nd to 8th harmonic of `lo`, within 40 cents?
overtone_of :: proc(hi, lo: f32) -> bool {
	ratio := math.pow(2, (hi - lo) / 12)
	k := math.round(ratio)
	if k < 2 || k > 8 do return false
	return abs(12 * math.log2(ratio / k)) < 0.4
}

// ---------------------------------------------------------------------------
// Checking against the song
// ---------------------------------------------------------------------------

// One reading's verdict on one expected note (MIDI m), of the `expected`
// notes all meant to be sounding then (m among them).
Check_Frame :: enum u8 {
	Miss, // nothing there
	Near, // there but out of tune, or a semitone off, or in another octave
	Good, // there, within CHECK_TUNE cents
}

CHECK_TUNE :: 25 // cents either way that count as in tune
CHECK_PRESENT :: 38 // presence (of 255) that counts as played, when not found outright

chord_check :: proc(r: ^Chord_Reading, m: int, expected: []int) -> (Check_Frame, int) {
	// Found outright?
	for f in r.notes[:r.n] {
		if abs(f - f32(m)) < 0.5 {
			c := int(math.round((f - f32(m)) * 100))
			return abs(c) <= CHECK_TUNE ? .Good : .Near, c
		}
	}
	// There, though quieter than the notes found?
	s := m - r.base
	if s >= 0 && s < CHORD_SPAN && r.presence[s] >= CHECK_PRESENT {
		c := int(r.cents[s])
		return abs(c) <= CHECK_TUNE ? .Good : .Near, c
	}
	// Close: a semitone off, or the right note in another octave - but not
	// by way of a note that is another expected note, played right (the A3
	// of a chord does not make a missing A4 nearly played).
	for f in r.notes[:r.n] {
		taken := false
		for e in expected do if e != m && abs(f - f32(e)) < 0.5 do taken = true
		if taken do continue
		dm := f - f32(m)
		if abs(dm) < 1.5 do return .Near, int(math.round(dm * 100))
		oct := math.round(dm / 12)
		if oct != 0 && abs(dm - oct * 12) < 0.5 do return .Near, 0
	}
	return .Miss, 0
}

// A note's readings, added up while it sounds.
Check_Tally :: struct {
	frames, good, near: i32,
	cents_sum:          i32, // over good and near frames
}

Check_Verdict :: enum u8 {
	None,
	Missed,
	Almost,
	Correct,
}

check_add :: proc(t: ^Check_Tally, f: Check_Frame, cents: int) {
	t.frames += 1
	switch f {
	case .Good:
		t.good += 1
		t.cents_sum += i32(cents)
	case .Near:
		t.near += 1
		t.cents_sum += i32(cents)
	case .Miss:
	}
}

// Correct: in tune for at least half the note. Almost: there (in tune or
// near it) for at least 40 % of it. Missed: otherwise.
check_verdict :: proc(t: Check_Tally) -> Check_Verdict {
	if t.frames == 0 do return .None
	if t.good * 2 >= t.frames do return .Correct
	if (t.good + t.near) * 5 >= t.frames * 2 do return .Almost
	return .Missed
}

// How much of a note at `f` Hz there is: its harmonics, weighted - less
// whatever lies half way between them. A real note has little there; a
// "note" made up out of some lower note's close-packed harmonics (under a
// low C every candidate high up finds a harmonic near its own) has as much
// between as on.
@(private)
chord_salience :: #force_inline proc(d: ^Chord_Detector, f, binw: f32) -> f32 #no_bounds_check {
	s: f32
	top := f32(d.n / 2 - 2)
	peak :: #force_inline proc(d: ^Chord_Detector, b, top: f32) -> f32 {
		w := max(b * CHORD_WIDTH, 1)
		lo := int(max(b - w, 1))
		hi := int(min(b + w, top))
		v: f32
		for k in lo ..= hi do v = max(v, d.spec[k])
		return v
	}
	for h in 1 ..= CHORD_H {
		fh := f * f32(h)
		if fh > CHORD_TOP_HZ do break
		on := peak(d, fh / binw, top)
		between := peak(d, (fh + 0.5 * f) / binw, top)
		s += max(on - 0.5 * between, 0) * (f + 27) / (fh + 320)
	}
	return s
}

// Where the note really is: from its harmonics' peaks, each placed to a
// fraction of a bin (a parabola through the peak and its neighbours).
@(private)
chord_refine :: proc(d: ^Chord_Detector, f, binw: f32) -> (f32, bool) #no_bounds_check {
	top := d.n / 2 - 2
	num, den: f32
	for h in 1 ..= 8 {
		fh := f * f32(h)
		if fh > CHORD_TOP_HZ do break
		b := fh / binw
		w := max(b * CHORD_WIDTH * 2, 1)
		lo := int(max(b - w, 1))
		hi := min(int(b + w), top)
		p := lo
		for k in lo ..= hi do if d.spec[k] > d.spec[p] do p = k
		if d.spec[p] <= 0 || p <= 0 || p >= top do continue
		a := math.ln(max(d.mag[p - 1], 1e-9))
		bb := math.ln(max(d.mag[p], 1e-9))
		c := math.ln(max(d.mag[p + 1], 1e-9))
		den2 := a - 2 * bb + c
		delta := den2 < 0 ? clamp(0.5 * (a - c) / den2, -0.5, 0.5) : 0
		est := (f32(p) + delta) * binw / f32(h)
		// Only harmonics that agree with the candidate (a quarter tone).
		if abs(est / f - 1) > 0.03 do continue
		wt := d.spec[p] * f32(h)
		num += est * wt
		den += wt
	}
	return den > 0 ? num / den : f, den > 0
}

// Take a note's harmonics out of the spectrum - as much as a smooth run of
// harmonics would hold, so a shared partial keeps what the other note put
// there.
@(private)
chord_cancel :: proc(d: ^Chord_Detector, f, binw: f32) #no_bounds_check {
	top := d.n / 2 - 2
	// Every harmonic up to the top, not only those the salience looks at: a
	// low note's hundredth harmonic left behind is a high note's first.
	HMAX :: 120
	amp: [HMAX + 2]f32
	peak: [HMAX + 2]int
	hn := 0
	for h in 1 ..= HMAX {
		fh := f * f32(h)
		if fh > CHORD_TOP_HZ do break
		b := fh / binw
		w := max(b * CHORD_WIDTH * 2, 1)
		lo := int(max(b - w, 1))
		hi := min(int(b + w), top)
		p := lo
		for k in lo ..= hi do if d.spec[k] > d.spec[p] do p = k
		amp[h] = d.spec[p]
		peak[h] = p
		hn = h
	}
	for h in 1 ..= hn {
		a := amp[h]
		if a <= 0 do continue
		// Smooth: no more than the average of it and its neighbours.
		nb := a
		cnt := f32(1)
		if h > 1 {nb += amp[h - 1]; cnt += 1}
		if h < hn {nb += amp[h + 1]; cnt += 1}
		smooth := min(a, nb / cnt)
		keep := 1 - smooth / a
		p := peak[h]
		for k in max(p - 3, 1) ..= min(p + 3, top) do d.spec[k] *= keep
	}
}

// In-place radix-2 FFT. `cos_t`, `sin_t`: cos and sin of 2 pi k / n, k < n/2.
fft :: proc(re, im: []f32, cos_t, sin_t: []f32) #no_bounds_check {
	n := len(re)
	j := 0
	for i in 1 ..< n {
		bit := n >> 1
		for j & bit != 0 {
			j ~= bit
			bit >>= 1
		}
		j ~= bit
		if i < j {
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
		}
	}
	for size := 2; size <= n; size <<= 1 {
		h := size / 2
		step := n / size
		for i := 0; i < n; i += size {
			for k in 0 ..< h {
				wr := cos_t[k * step]
				wi := -sin_t[k * step]
				a := i + k
				b := a + h
				vr := re[b] * wr - im[b] * wi
				vi := re[b] * wi + im[b] * wr
				re[b] = re[a] - vr
				im[b] = im[a] - vi
				re[a] += vr
				im[a] += vi
			}
		}
	}
}
