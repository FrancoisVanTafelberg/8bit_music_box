package music

/*
    AUDIO IMPORT: a recording in, a rough draft of its notes out.

    Not a finished transcription - nothing does that reliably - but a draft
    to correct on the sheet: the notes it is sure of in the right places, so
    the work left is fixing, not writing from nothing.

        samples, rate, ok := wav_read("imports/tune.wav")   // or decoded by ffmpeg
        job: Audio_Import
        audio_import_begin(&job, samples, rate, opts)
        for !audio_import_step(&job, 10 * time.Millisecond) {}  // a slice at a time
        audio_import_song(&job, &song)                         // the draft, as a Song

    FOUR STAGES.

    1. HEARING. The recording is brought to PITCH_RATE, mono, and run through
       the chord detector (chord.odin) - the same one the microphone uses -
       every 12 ms: which notes are sounding, how loud. One voice: its
       single-note mode (the note, not its overtones); more: up to that many
       notes at once.

    2. NOTES. A note starts where a pitch appears and ends where it goes. A
       note played again at the same pitch would just run on, so a sudden
       rise in loudness (an ONSET: a bow change, a new pluck) ends every note
       sounding and starts it afresh. Notes shorter than `min_len` are
       dropped: a scrape, a passing ghost.

    3. TIME (AND KEY). The tempo is guessed from when the onsets fall: the beat length
       whose grid lines up with the most onsets, between 50 and 200 beats a
       minute (a tempo can always be set by hand). Then the grid is slid
       through a beat to where the onsets fit it best, and every start and
       end is snapped to the grid (a 16th by default). The key signature is
       the one whose scale holds the most of the music.

    4. VOICES AND LAYERS. With more than one voice, the notes sounding
       together are ranked by pitch, the highest voice 1. Each voice becomes
       a layer for each instrument asked for - so a tune can be had for viola
       AND cello, every voice of it, to practise on either - moved by octaves
       to sit in that instrument's range (the whole voice at once, so its
       shape is kept; only notes still outside are folded in on their own).

    Everything is in this package, so the editor runs it a slice per frame
    and a tool can run it in one go (tools/audio_test).
*/

import "core:math"
import "core:os"
import "core:slice"
import "core:strings"

AUDIO_IMPORT_MAX_VOICES :: 4
AUDIO_IMPORT_MAX_INSTS :: 2
AUDIO_IMPORT_LEAD :: PITCH_RATE / 4 // samples of silence put before the recording

Audio_Import_Options :: struct {
	voices:      int, // 1 = a melody (single-note mode)
	lo, hi:      f32, // MIDI: the notes listened for
	sensitivity: f32, // the gate, as the mic's (x2 = 6 dB above the room)
	tempo:       f32, // 0 = guess it
	beats:       i32, // time signature
	beat_unit:   i32,
	grid:        i32, // ticks to snap to: 6 = 16th
	min_len:     f32, // seconds: shorter notes are dropped
	insts:       [AUDIO_IMPORT_MAX_INSTS]string, // instrument keys; "" = none
}

audio_import_defaults :: proc() -> Audio_Import_Options {
	return {
		voices = 1,
		lo = 28, // E1
		hi = 96, // C7
		sensitivity = PITCH_SENSITIVITY_DEFAULT,
		beats = 4,
		beat_unit = 4,
		grid = 6,
		min_len = 0.06,
		insts = {"cello", "viola"},
	}
}

// A note as heard, in seconds.
Heard_Note :: struct {
	start, end: f32,
	midi:       f32, // the average over the note
	level:      f32,
	voice:      int,
}

Audio_Import :: struct {
	opts:      Audio_Import_Options,
	samples:   [dynamic]f32, // mono, PITCH_RATE
	pos:       int, // fed this far
	det:       Chord_Detector,
	// Notes being followed, by semitone.
	open:      [128]Open_Note,
	notes:     [dynamic]Heard_Note,
	onsets:    [dynamic]f32, // seconds, found before hearing starts
	next:      int, // the next onset not yet reached
	last:      f32, // the last onset passed (-1: none)
	done:      bool,
	tempo:     f32, // guessed (or as asked)
	offset:    f32, // seconds: where the grid starts
}

@(private)
Open_Note :: struct {
	on:     bool,
	start:  f32,
	sum:    f32, // of fractional MIDI, for the average
	n:      int,
	level:  f32,
}

audio_import_destroy :: proc(j: ^Audio_Import) {
	delete(j.samples)
	delete(j.notes)
	delete(j.onsets)
	j^ = {}
}

// Seconds of recording.
audio_import_length :: proc(j: ^Audio_Import) -> f32 {return f32(max(len(j.samples) - AUDIO_IMPORT_LEAD, 0)) / PITCH_RATE}

// 0..1, how far it has got.
audio_import_progress :: proc(j: ^Audio_Import) -> f32 {
	return len(j.samples) > 0 ? f32(j.pos) / f32(len(j.samples)) : 1
}

// Start: `samples` mono at `rate` (any rate; brought to PITCH_RATE here).
audio_import_begin :: proc(j: ^Audio_Import, samples: []f32, rate: int, opts: Audio_Import_Options) {
	audio_import_destroy(j)
	j.opts = opts
	j.opts.voices = clamp(opts.voices, 1, AUDIO_IMPORT_MAX_VOICES)
	// To PITCH_RATE, linearly (the detector looks no higher than 5 kHz).
	// The recording, after AUDIO_IMPORT_LEAD of its own quietest moment:
	// the detector learns the room from what it hears first, and a
	// recording that starts on a note would teach it that the note IS the
	// room (and one that starts in hiss and hum must teach it those).
	ratio := f64(rate) / PITCH_RATE
	n := int(f64(len(samples)) / ratio)
	resize(&j.samples, n + AUDIO_IMPORT_LEAD)
	for i in 0 ..< n {
		p := f64(i) * ratio
		k := int(p)
		f := f32(p - f64(k))
		a := samples[min(k, len(samples) - 1)]
		b := samples[min(k + 1, len(samples) - 1)]
		j.samples[AUDIO_IMPORT_LEAD + i] = a + (b - a) * f
	}
	// Normalised, so the gate works on a quiet recording too.
	peak: f32
	for s in j.samples do peak = max(peak, abs(s))
	if peak > 0 do for &s in j.samples do s *= 0.7 / peak
	if n > AUDIO_IMPORT_LEAD * 2 {
		body := j.samples[AUDIO_IMPORT_LEAD:]
		quiet, quiet_e, loud_e := 0, f32(1e30), f32(0)
		for at := 0; at + AUDIO_IMPORT_LEAD <= len(body); at += AUDIO_IMPORT_LEAD / 4 {
			e: f32
			for s in body[at:at + AUDIO_IMPORT_LEAD] do e += s * s
			if e < quiet_e {quiet, quiet_e = at, e}
			loud_e = max(loud_e, e)
		}
		// Only if it is quiet: 20 dB under the loudest. Otherwise silence.
		if quiet_e < loud_e * 0.01 do copy(j.samples[:AUDIO_IMPORT_LEAD], body[quiet:quiet + AUDIO_IMPORT_LEAD])
	}
	find_onsets(j)
	j.last = -1
	chord_init(&j.det, opts.lo, opts.hi)
	j.det.sensitivity = opts.sensitivity
	j.det.max_notes = j.opts.voices
	j.det.single = j.opts.voices == 1
}

// Hear the next stretch, for about `budget` seconds of work. Returns true
// when it has heard all of it (and the notes, tempo and grid are worked out).
audio_import_step :: proc(j: ^Audio_Import, budget_samples: int) -> bool {
	if j.done do return true
	readings: [64]Chord_Reading
	for left := budget_samples; left > 0 && j.pos < len(j.samples); {
		take := min(left, CHORD_HOP * 32, len(j.samples) - j.pos)
		k := chord_feed(&j.det, j.samples[j.pos:j.pos + take], readings[:])
		j.pos += take
		left -= take
		for r in readings[:k] do heard(j, r, f32(j.pos - r.delay - AUDIO_IMPORT_LEAD) / PITCH_RATE)
	}
	if j.pos < len(j.samples) do return false
	// The end: every note still sounding ends here.
	end := audio_import_length(j)
	for m in 0 ..< 128 do close_note(j, m, end)
	finish(j)
	j.done = true
	return true
}

@(private)
heard :: proc(j: ^Audio_Import, reading: Chord_Reading, t: f32) {
	r := reading
	// Onsets passed since the last reading: every note sounding is played
	// again (that is how a repeated note is told from a long one).
	for j.next < len(j.onsets) && j.onsets[j.next] <= t {
		o := j.onsets[j.next]
		for m in 0 ..< 128 {
			on := &j.open[m]
			if !on.on do continue
			// Heard only just before the onset: the detector's window
			// reaching ahead - it is the onset's note.
			if on.start > o - 0.12 do on.start = o
			else do close_note(j, m, o)
		}
		j.last = o
		j.next += 1
	}
	now: [128]bool
	// One voice: only the strongest note (the detector's single mode).
	count := j.opts.voices == 1 ? min(r.n, 1) : r.n
	for f in r.notes[:count] {
		m := clamp(int(math.round(f)), 0, 127)
		now[m] = true
		add_reading(j, m, f, r.level, t)
	}
	for m in 0 ..< 128 do if j.open[m].on && !now[m] do close_note(j, m, t)
}

@(private)
add_reading :: proc(j: ^Audio_Import, m: int, f, level, t: f32) {
	o := &j.open[m]
	// A note heard just after an onset began AT the onset: the detector,
	// listening through a window 90-190 ms long, is always a little late.
	if !o.on do o^ = {on = true, start = j.last >= 0 && t - j.last < 0.12 ? j.last : t}
	o.sum += f
	o.n += 1
	o.level = max(o.level, level)
}

@(private)
close_note :: proc(j: ^Audio_Import, m: int, t: f32) {
	o := &j.open[m]
	if !o.on do return
	if t - o.start >= j.opts.min_len && o.n > 0 {
		append(&j.notes, Heard_Note{start = o.start, end = t, midi = o.sum / f32(o.n), level = o.level})
	}
	o^ = {}
}

// Where notes are struck, bowed again or tongued: the loudness, every 6 ms,
// rising quickly to well above where it was a moment before. Found for the
// whole recording first (it takes a few ms), so hearing can use them.
@(private)
find_onsets :: proc(j: ^Audio_Import) {
	HOP :: 128 // 5.8 ms
	WIDE :: 512 // measured over 23 ms: a whole wave of the lowest notes, or
	// the loudness would rise and fall with the wave itself
	BACK :: 8 // looked back over (46 ms)
	n := len(j.samples) / HOP
	env := make([]f32, n, context.temp_allocator)
	for k in 0 ..< n {
		a := max(k * HOP + HOP / 2 - WIDE / 2, 0)
		b := min(a + WIDE, len(j.samples))
		sum: f32
		for s in j.samples[a:b] do sum += s * s
		env[k] = math.sqrt(sum / f32(max(b - a, 1)))
	}
	last := -1000
	for k in BACK ..< n - 2 {
		low := env[k - 1]
		for b in 1 ..= BACK do low = min(low, env[k - b])
		// Rising fast now, and soon well above the low point.
		peak := max(env[k], env[k + 1], env[k + 2])
		if env[k] > env[k - 1] * 1.12 && peak > max(low * 1.5, 0.02) && k - last > 14 {
			append(&j.onsets, f32((k - 1) * HOP - AUDIO_IMPORT_LEAD) / PITCH_RATE)
			last = k
		}
	}
}

// The tempo, the grid's start, and the voices.
@(private)
finish :: proc(j: ^Audio_Import) {
	slice.sort_by(j.notes[:], proc(a, b: Heard_Note) -> bool {return a.start < b.start || (a.start == b.start && a.midi > b.midi)})
	// The onsets are the note starts if the loudness never jumped (an organ).
	if len(j.onsets) < 4 {
		clear(&j.onsets)
		for n in j.notes do if len(j.onsets) == 0 || n.start - j.onsets[len(j.onsets) - 1] > 0.08 do append(&j.onsets, n.start)
	}
	j.tempo = j.opts.tempo > 0 ? j.opts.tempo : guess_tempo(j.onsets[:])
	j.offset = best_offset(j.onsets[:], 60 / j.tempo / 4)
	// Voices: among the notes sounding at a note's start, its rank by
	// pitch, highest first.
	for &n, i in j.notes {
		rank := 0
		for o, k in j.notes {
			if k == i do continue
			if o.start <= n.start + 0.03 && o.end > n.start + 0.03 && o.midi > n.midi do rank += 1
		}
		n.voice = min(rank, j.opts.voices - 1)
	}
}

// The beat (as a tempo) that most onsets fall on: for each candidate, how
// close every interval between nearby onsets is to a whole number of beats.
@(private)
guess_tempo :: proc(onsets: []f32) -> f32 {
	if len(onsets) < 3 do return 120
	best, best_score := f32(120), f32(-1)
	for bpm := f32(50); bpm <= 200; bpm += 0.5 {
		beat := 60 / bpm
		score: f32
		for i in 0 ..< len(onsets) {
			for k in i + 1 ..< min(i + 8, len(onsets)) {
				d := (onsets[k] - onsets[i]) / beat
				// Halves and quarters of the beat count too, a little.
				subs := [3]f32{1, 2, 4}
				weights := [3]f32{1, 0.35, 0.15}
				for w in 0 ..< 3 {
					x := d * subs[w]
					off := abs(x - math.round(x))
					score += (1 - min(off * 4, 1)) * weights[w]
				}
			}
		}
		// A mild pull toward moderate tempos: twice as fast fits as well.
		score *= 1 - 0.15 * abs(math.log2(bpm / 100))
		if score > best_score {best, best_score = bpm, score}
	}
	return math.round(best)
}

// Where the grid (step seconds) lines up best with the onsets.
@(private)
best_offset :: proc(onsets: []f32, step: f32) -> f32 {
	if len(onsets) == 0 do return 0
	best, best_err := f32(0), f32(1e30)
	for k in 0 ..< 24 {
		off := step * f32(k) / 24
		err: f32
		for o in onsets {
			x := (o - off) / step
			d := x - math.round(x)
			err += d * d
		}
		if err < best_err {best, best_err = off, err}
	}
	// Starting before the first onset, by whole grid steps.
	first := onsets[0]
	for best + step <= first do best += step
	return best
}

// The draft, as a song: replaces what is in `song`. Returns how many notes,
// layers, and notes moved by octaves into range.
audio_import_song :: proc(j: ^Audio_Import, song: ^Song, title: string) -> (notes, layers, moved: int) {
	song_destroy(song)
	song_init(song)
	song_set_title(song, title)
	song.tempo = clamp(j.tempo, 20, 400)
	song.beats = j.opts.beats
	song.beat_unit = j.opts.beat_unit
	song.key = i32(guess_key(j.notes[:]))
	sig := int(song.key)
	spt := f32(tick_seconds(song))
	grid := max(j.opts.grid, 1)
	snap :: proc(t, offset, spt: f32, grid: i32) -> i32 {
		ticks := (t - offset) / spt
		return max(i32(math.round(ticks / f32(grid))) * grid, 0)
	}
	n_insts := 0
	for k in j.opts.insts do if k != "" do n_insts += 1
	for v in 0 ..< j.opts.voices {
		for key in j.opts.insts {
			if key == "" do continue
			id, ok := registry_find(reg(), key)
			if !ok do continue
			ins := reg().list[id]
			ti := song_add_track(song, id, j.opts.voices > 1 ? fmt_voice(ins.name, v) : ins.name)
			t := &song.tracks[ti]
			// The whole voice by octaves into the instrument's range: the
			// shift that puts the most of its notes inside.
			shift, inside := 0, -1
			for s := -4; s <= 4; s += 1 {
				c := 0
				for n in j.notes do if n.voice == v {
					m := int(math.round(n.midi)) + s * 12
					if i32(m) >= ins.lo && i32(m) <= ins.hi do c += 1
				}
				if c > inside || (c == inside && abs(s) < abs(shift)) {inside, shift = c, s}
			}
			for n in j.notes {
				if n.voice != v do continue
				m := int(math.round(n.midi)) + shift * 12
				for i32(m) < ins.lo {m += 12; moved += 1}
				for i32(m) > ins.hi {m -= 12; moved += 1}
				a := snap(n.start, j.offset, spt, grid)
				b := max(snap(n.end, j.offset, spt, grid), a + grid)
				vel := u8(clamp(40 + n.level * 120, 40, 127))
				// Spelt in the key guessed.
				append(&t.notes, Note{tick = a, len = b - a, pitch = pitch_from_midi(m, sig), vel = vel})
			}
			track_sort(t)
			// One line: in a single voice a note ends where the next begins
			// (snapping can make them overlap); in any voice, the same pitch
			// twice at the same tick is one note.
			for i := len(t.notes) - 1; i > 0; i -= 1 {
				p, q := &t.notes[i - 1], t.notes[i]
				if p.tick == q.tick && pitch_midi(p.pitch) == pitch_midi(q.pitch) {
					p.len = max(p.len, q.len)
					ordered_remove(&t.notes, i)
				}
			}
			for i in 0 ..< len(t.notes) {
				n := &t.notes[i]
				for k in i + 1 ..< len(t.notes) {
					o := t.notes[k]
					if o.tick <= n.tick do continue
					if j.opts.voices == 1 || pitch_midi(o.pitch) == pitch_midi(n.pitch) {
						if n.tick + n.len > o.tick do n.len = o.tick - n.tick
						break
					}
				}
			}
			notes += len(t.notes)
			layers += 1
		}
	}
	song_fit_bars(song, 4)
	return
}

// The key signature (sharps +, flats -): the major or minor key whose
// profile (Krumhansl and Kessler's: how much each degree of a key is heard
// in music in it) best matches how long each pitch class sounds - which
// tells D major from G major even in a tune that never plays the C#.
@(private)
guess_key :: proc(notes: []Heard_Note) -> int {
	weight: [12]f32
	for n in notes do weight[(int(math.round(n.midi)) % 12 + 12) % 12] += n.end - n.start
	MAJOR :: [12]f32{6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88}
	MINOR :: [12]f32{6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17}
	// The signature of each major key's tonic (C=0 ... B=11), flats past F#.
	sig := [12]int{0, -5, 2, -3, 4, -1, 6, 1, -4, 3, -2, 5}
	corr :: proc(w: [12]f32, prof: [12]f32, tonic: int) -> f32 {
		mw, mp: f32
		for i in 0 ..< 12 {mw += w[i]; mp += prof[i]}
		mw /= 12
		mp /= 12
		num, dw, dp: f32
		for i in 0 ..< 12 {
			a := w[(tonic + i) % 12] - mw
			b := prof[i] - mp
			num += a * b
			dw += a * a
			dp += b * b
		}
		return dw > 0 ? num / math.sqrt(dw * dp) : 0
	}
	best, best_r := 0, f32(-2)
	for t in 0 ..< 12 {
		if r := corr(weight, MAJOR, t); r > best_r {best, best_r = sig[t], r}
		// A minor key has its relative major's signature (three up).
		if r := corr(weight, MINOR, t); r > best_r {best, best_r = sig[(t + 3) % 12], r}
	}
	return best
}

@(private)
fmt_voice :: proc(name: string, v: int) -> string {
	return strings.concatenate({name, " ", VOICE_NAMES[min(v, len(VOICE_NAMES) - 1)]}, context.temp_allocator)
}

@(private)
VOICE_NAMES := [4]string{"1 (top)", "2", "3", "4"}

// ---------------------------------------------------------------------------
// Reading a WAV file
// ---------------------------------------------------------------------------

// A .wav as mono f32 (-1..1) and its sample rate: 8, 16, 24 or 32-bit PCM,
// or 32-bit float, any number of channels (averaged).
wav_read :: proc(path: string, allocator := context.allocator) -> (samples: []f32, rate: int, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil || len(data) < 12 do return
	if string(data[0:4]) != "RIFF" || string(data[8:12]) != "WAVE" do return
	u16le :: proc(b: []u8, at: int) -> int {return int(b[at]) | int(b[at + 1]) << 8}
	u32le :: proc(b: []u8, at: int) -> int {return u16le(b, at) | u16le(b, at + 2) << 16}
	format, channels, bits := 0, 0, 0
	at := 12
	for at + 8 <= len(data) {
		id := string(data[at:at + 4])
		size := u32le(data, at + 4)
		body := at + 8
		if body + size > len(data) do size = len(data) - body
		switch id {
		case "fmt ":
			if size < 16 do return
			format = u16le(data, body)
			channels = u16le(data, body + 2)
			rate = u32le(data, body + 4)
			bits = u16le(data, body + 14)
			if format == 0xFFFE && size >= 26 do format = u16le(data, body + 24) // extensible
		case "data":
			if channels <= 0 || bits <= 0 do return
			bps := bits / 8
			frames := size / (bps * channels)
			out := make([]f32, frames, allocator)
			for f in 0 ..< frames {
				sum: f32
				for c in 0 ..< channels {
					p := body + (f * channels + c) * bps
					v: f32
					switch {
					case format == 3 && bits == 32:
						v = transmute(f32)u32(u32le(data, p))
					case bits == 8:
						v = (f32(data[p]) - 128) / 128
					case bits == 16:
						v = f32(i16(u16le(data, p))) / 32768
					case bits == 24:
						x := i32(u32(data[p]) << 8 | u32(data[p + 1]) << 16 | u32(data[p + 2]) << 24)
						v = f32(x >> 8) / 8388608
					case bits == 32:
						v = f32(i32(u32(u32le(data, p)))) / 2147483648
					}
					sum += v
				}
				out[f] = sum / f32(channels)
			}
			return out, rate, rate > 0
		}
		at = body + size + (size & 1)
	}
	return
}
