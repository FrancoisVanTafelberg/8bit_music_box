package chord_test

/*
    Checks the input mode's chord detection (source/music/chord.odin) with no
    microphone: chords are rendered with the app's own engine - cello double
    stops, piano triads, guitar chords, and single notes - a room's noise is
    added (hiss, mains hum, a fan, a murmur of voices), and the result is fed
    to the detector as the mic would feed it.

    For every reading in the steady middle of each chord: which of its notes
    were found (recall: of up to three notes - the goal is three-note chords),
    and whether anything was found that is not in it (a false note). Also the
    time each analysis takes.

        odin run tools/chord_test -o:speed
        odin run tools/chord_test -o:speed -- -noisy      (the room 12 dB louder)
        odin run tools/chord_test -o:speed -- -v          (every chord's figures)
*/

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:time"
import music "../../source/music"

Case :: struct {
	name:   string,
	inst:   string,
	chords: [][]int,
	// Plucked or struck: the synth's note has died away after about a
	// second, so only its first second is scored.
	decays: bool,
	// Beyond the goal (three-note chords): scored and shown, not required.
	extra:  bool,
}

main :: proc() {
	reg: music.Registry
	music.registry_init(&reg)
	music.registry_bind(&reg)
	irep: music.Load_Report
	music.registry_load_dir(&reg, music.INST_DIR, &irep)
	music.registry_ensure(&reg)

	noise := f32(1)
	verbose := false
	dump := ""
	for a in os.args[1:] {
		if a == "-noisy" do noise = 4
		else if a == "-v" do verbose = true
		else do dump = a // a case's instrument: print its readings
	}

	cases := []Case {
		{"cello, single notes", "cello", {{36}, {43}, {50}, {57}, {62}, {69}, {41}, {74}, {81}}, false, false},
		{"cello, double stops", "cello", {{43, 50}, {50, 57}, {48, 55}, {45, 53}, {50, 59}, {55, 62}, {57, 64}, {48, 60}, {43, 59}}, false, false},
		{"cello, triple stops", "cello", {{43, 50, 57}, {36, 43, 52}, {50, 57, 66}}, false, false},
		{"piano, triads", "piano", {{60, 64, 67}, {57, 60, 64}, {53, 57, 60}, {55, 59, 62}, {48, 52, 55}, {74, 78, 81}, {48, 55, 64}, {62, 65, 69}, {45, 52, 60}}, true, false},
		{"piano, single notes", "piano", {{40}, {48}, {60}, {67}, {76}, {84}}, true, false},
		{"guitar, chords", "guitar", {{40, 47, 52, 56, 59, 64}, {48, 52, 55, 60, 64}, {43, 47, 50, 55, 59, 67}, {45, 52, 57, 60, 64}, {50, 57, 62, 66}}, true, true},
		{"violin, double stops", "violin", {{55, 62}, {62, 69}, {69, 76}, {64, 71}, {67, 74}}, false, false},
	}

	all_ok := true
	us_total: f64
	us_n: int
	us_max: f64
	for c in cases {
		for mode in ([2]music.Sound_Mode{.Bit16, .Bit8}) {
			song: music.Song
			music.song_init(&song)
			song.tempo = 60
			ti := music.song_add_track(&song, c.inst)
			spt := music.tick_seconds(&song)
			tick := i32(music.TPQ * 4) // a bar of room first
			Seg :: struct {start, end: f64, notes: []int}
			segs := make([dynamic]Seg)
			for ch in c.chords {
				ln := i32(music.TPQ * 2) // two seconds at 60
				for m in ch do append(&song.tracks[ti].notes, music.Note{tick, ln, music.pitch_from_midi(m, 0), 100})
				append(&segs, Seg{f64(tick) * spt, f64(tick + ln) * spt, ch})
				tick += ln + music.TPQ / 2 // and a half-beat rest
			}
			music.track_sort(&song.tracks[ti])
			stereo := music.render_song(&song, mode)
			n := len(stereo) / 4
			mic := make([]f32, n + music.PITCH_RATE)
			for i in 0 ..< n {
				k := i * 4
				mic[i] = (stereo[k] + stereo[k + 1] + stereo[k + 2] + stereo[k + 3]) * 0.25
			}
			peak: f32
			for s in mic do peak = max(peak, abs(s))
			for &s in mic do s *= 0.3 / max(peak, 1e-6)
			rng := rand.create(99)
			context.random_generator = rand.default_random_generator(&rng)
			rumble, v1, v2: f32
			for i in 0 ..< len(mic) {
				t := f32(i) / music.PITCH_RATE
				hiss := rand.float32_range(-1, 1) * 0.005
				hum := 0.006 * math.sin(2 * math.PI * 50 * t) + 0.003 * math.sin(2 * math.PI * 150 * t)
				rumble += (rand.float32_range(-1, 1) - rumble) * 0.01
				v1 += (rand.float32_range(-1, 1) - v1) * 0.12
				v2 += (v1 - v2) * 0.3
				murmur := (v1 - v2) * 0.02 * (0.6 + 0.4 * math.sin(2 * math.PI * 0.7 * t))
				mic[i] += (hiss + hum + rumble * 0.05 + murmur) * noise
			}

			ins := music.inst_get(&song, song.tracks[ti].inst)
			d := new(music.Chord_Detector)
			music.chord_init(d, f32(ins.lo), f32(ins.hi))
			out := make([]music.Chord_Reading, 64)
			right := make([]int, len(segs))
			want := make([]int, len(segs))
			false_n := make([]int, len(segs))
			seen := make([]int, len(segs))
			silent_false, silent_n := 0, 0
			for at := 0; at < len(mic); at += 512 {
				chunk := mic[at:min(at + 512, len(mic))]
				t0 := time.tick_now()
				k := music.chord_feed(d, chunk, out)
				us := time.duration_microseconds(time.tick_since(t0))
				if k > 0 {
					us_total += us
					us_n += k
					us_max = max(us_max, us / f64(k))
				}
				for &r in out[:k] {
					t := f64(at + len(chunk) - r.delay) / music.PITCH_RATE
					which := -1
					for s, i in segs do if t >= s.start + (c.decays ? 0.12 : 0.25) && t < (c.decays ? s.start + 0.9 : s.end - 0.1) do which = i
					between := true
					for s in segs do if t >= s.start - 0.1 && t < s.end + 0.45 do between = false
					if dump == c.inst && mode == .Bit16 && which >= 0 && seen[which] % 20 == 0 {
						fmt.printfln("  %v t=%.2f lvl %.3f floor %.3f open %v found %v", segs[which].notes, t, r.level, d.floor, d.open, r.notes[:r.n])
					}
					if which >= 0 {
						s := segs[which]
						seen[which] += 1
						got := 0
						for m in s.notes {
							for f in r.notes[:r.n] do if abs(f - f32(m)) < 0.5 {got += 1; break}
						}
						right[which] += min(got, 3)
						want[which] += min(len(s.notes), 3)
						for f in r.notes[:r.n] {
							ok := false
							for m in s.notes do if abs(f - f32(m)) < 0.5 do ok = true
							if !ok do false_n[which] += 1
						}
					} else if between {
						silent_n += 1
						silent_false += r.n
					}
				}
			}
			tr, tw, tf, ts := 0, 0, 0, 0
			for i in 0 ..< len(segs) {
				tr += right[i]
				tw += want[i]
				tf += false_n[i]
				ts += seen[i]
				if verbose {
					fmt.printfln("    %v  recall %3d%%  false %.2f/reading", segs[i].notes, 100 * right[i] / max(want[i], 1), f64(false_n[i]) / f64(max(seen[i], 1)))
				}
			}
			recall := 100 * tr / max(tw, 1)
			false_rate := f64(tf) / f64(max(ts, 1))
			fmt.printfln("%-22s %-6v recall %3d%%   false notes %.2f a reading   silence: %d false in %d%s", c.name, mode, recall, false_rate, silent_false, silent_n, c.extra ? "   (beyond the goal)" : "")
			if !c.extra && (recall < (noise > 1 ? 75 : 85) || false_rate > 0.2) do all_ok = false
			if silent_false > silent_n / 20 do all_ok = false
			free(d)
		}
	}
	fmt.printfln("analysis: %.0f us on average, %.0f us at most", us_total / f64(max(us_n, 1)), us_max)

	// Single-note mode: a note with overtones strong enough to be found as
	// notes of their own (a cello's open C: its octave, twelfth and double
	// octave played along with it, loud) must come out as the one note.
	fmt.println("\nSingle-note mode (played, with overtones -> what it says)")
	Single_Case :: struct {
		name:   string,
		inst:   string,
		root:   int,
		extra:  []int, // "overtones", played with it
		vel:    []u8,
	}
	singles := []Single_Case {
		{"cello C2 + loud 8va, 12th, 15th", "cello", 36, {48, 55, 60}, {115, 95, 80}},
		{"cello G2 + loud 8va, 12th", "cello", 43, {55, 62}, {120, 100}},
		{"cello D3 + loud 8va", "cello", 50, {62}, {127}},
		{"cello C2 + overtones louder than it", "cello", 36, {48, 55, 60, 64}, {127, 127, 120, 110}},
		{"cello C2 alone", "cello", 36, {}, {}},
		{"cello A3 alone", "cello", 57, {}, {}},
		{"piano C3 + loud 8va, 12th", "piano", 48, {60, 67}, {120, 100}},
	}
	for sc in singles {
		song: music.Song
		music.song_init(&song)
		song.tempo = 60
		ti := music.song_add_track(&song, sc.inst)
		start := i32(music.TPQ * 4)
		append(&song.tracks[ti].notes, music.Note{start, music.TPQ * 2, music.pitch_from_midi(sc.root, 0), 100})
		for m, i in sc.extra do append(&song.tracks[ti].notes, music.Note{start, music.TPQ * 2, music.pitch_from_midi(m, 0), sc.vel[i]})
		music.track_sort(&song.tracks[ti])
		stereo := music.render_song(&song, .Bit16)
		n := len(stereo) / 4
		mic := make([]f32, n)
		for i in 0 ..< n {
			k := i * 4
			mic[i] = (stereo[k] + stereo[k + 1] + stereo[k + 2] + stereo[k + 3]) * 0.25
		}
		peak: f32
		for v in mic do peak = max(peak, abs(v))
		if peak > 0 do for &v in mic do v *= 0.3 / peak
		rng := rand.create(11)
		context.random_generator = rand.default_random_generator(&rng)
		for &v in mic do v += rand.float32_range(-1, 1) * 0.005 * noise
		ins := music.inst_get(&song, song.tracks[ti].inst)
		d := new(music.Chord_Detector)
		music.chord_init(d, f32(ins.lo), f32(ins.hi))
		d.single = true
		out := make([]music.Chord_Reading, 64)
		spt := music.tick_seconds(&song)
		t0 := f64(start) * spt
		t1 := t0 + (sc.inst == "piano" ? 0.9 : 1.9)
		right, total, other := 0, 0, 0
		for at := 0; at < len(mic); at += 512 {
			chunk := mic[at:min(at + 512, len(mic))]
			k := music.chord_feed(d, chunk, out)
			for &rd in out[:k] {
				t := f64(at + len(chunk) - rd.delay) / music.PITCH_RATE
				if t < t0 + 0.2 || t >= t1 do continue
				total += 1
				if rd.n == 1 && abs(rd.notes[0] - f32(sc.root)) < 0.5 do right += 1
				else if rd.n > 0 do other += 1
			}
		}
		pct := 100 * right / max(total, 1)
		fmt.printfln("  %-37s %3d%% %s, %d readings something else", sc.name, pct, music.pitch_name_temp(music.pitch_from_midi(sc.root, 0)), other)
		if pct < 90 do all_ok = false
		free(d)
	}

	// The Check mode: what was expected, what was played, what it says.
	fmt.println("\nCheck mode (expected -> played: verdicts)")
	Check_Case :: struct {
		name:     string,
		inst:     string,
		expected: []int,
		played:   []int,
		cents:    f32, // the whole take this far out of tune
		want:     []music.Check_Verdict,
	}
	C :: music.Check_Verdict.Correct
	A :: music.Check_Verdict.Almost
	M :: music.Check_Verdict.Missed
	checks := []Check_Case {
		{"right chord", "piano", {60, 64, 67}, {60, 64, 67}, 0, {C, C, C}},
		{"35 cents sharp", "piano", {60, 64, 67}, {60, 64, 67}, 35, {A, A, A}},
		{"a semitone up", "piano", {60, 64, 67}, {61, 65, 68}, 0, {A, A, A}},
		{"top note left out", "piano", {60, 64, 67}, {60, 64}, 0, {C, C, M}},
		{"nothing played", "piano", {60, 64, 67}, {}, 0, {M, M, M}},
		{"another chord (F major)", "piano", {60, 64, 67}, {65, 69, 72}, 0, {A, A, M}}, // C5 is C an octave up, F a semitone from E
		{"double stop", "cello", {50, 57}, {50, 57}, 0, {C, C}},
		{"double stop, 12 cents flat", "cello", {50, 57}, {50, 57}, -12, {C, C}},
		{"octave too high", "cello", {50}, {62}, 0, {A}},
		{"one of two", "cello", {50, 57}, {57}, 0, {M, C}},
		{"triple stop", "cello", {43, 50, 57}, {43, 50, 57}, 0, {C, C, C}},
		{"violin double stop", "violin", {62, 69}, {62, 69}, 0, {C, C}},
	}
	for cc in checks {
		song: music.Song
		music.song_init(&song)
		song.tempo = 60
		ti := music.song_add_track(&song, cc.inst)
		start := i32(music.TPQ * 4)
		for m in cc.played do append(&song.tracks[ti].notes, music.Note{start, music.TPQ * 2, music.pitch_from_midi(m, 0), 100})
		// Something at the end, so the render runs on through the note.
		append(&song.tracks[ti].notes, music.Note{start + music.TPQ * 4, 1, music.pitch_from_midi(cc.expected[0], 0), 1})
		music.track_sort(&song.tracks[ti])
		stereo := music.render_song(&song, .Bit16)
		// Down to the mic's rate, and out of tune by `cents`: read faster.
		ratio := f64(math.pow(2, cc.cents / 1200)) * 2
		n := int(f64(len(stereo) / 2) / ratio)
		mic := make([]f32, n)
		for i in 0 ..< n {
			pos := f64(i) * ratio
			k := int(pos)
			if k + 1 >= len(stereo) / 2 do break
			fr := f32(pos - f64(k))
			mic[i] = ((stereo[2 * k] + stereo[2 * k + 1]) * (1 - fr) + (stereo[2 * k + 2] + stereo[2 * k + 3]) * fr) * 0.5
		}
		peak: f32
		for v in mic do peak = max(peak, abs(v))
		if peak > 0 do for &v in mic do v *= 0.3 / peak
		rng := rand.create(7)
		context.random_generator = rand.default_random_generator(&rng)
		for &v in mic do v += rand.float32_range(-1, 1) * 0.005 * noise
		ins := music.inst_get(&song, song.tracks[ti].inst)
		d := new(music.Chord_Detector)
		music.chord_init(d, f32(ins.lo), f32(ins.hi))
		out := make([]music.Chord_Reading, 64)
		tallies := make([]music.Check_Tally, len(cc.expected))
		// The note, as the song has it (the take is shorter when sped up).
		spt := music.tick_seconds(&song)
		t0 := f64(start) * spt / (ratio / 2)
		t1 := f64(start + music.TPQ * 2) * spt / (ratio / 2)
		for at := 0; at < len(mic); at += 512 {
			chunk := mic[at:min(at + 512, len(mic))]
			k := music.chord_feed(d, chunk, out)
			for &rd in out[:k] {
				t := f64(at + len(chunk) - rd.delay) / music.PITCH_RATE
				if t < t0 + 0.12 || t >= (cc.inst == "piano" ? t0 + 0.9 : t1 - 0.05) do continue
				for m, i in cc.expected {
					f, c := music.chord_check(&rd, m, cc.expected)
					music.check_add(&tallies[i], f, c)
				}
			}
		}
		got := make([]music.Check_Verdict, len(cc.expected))
		ok := true
		for t, i in tallies {
			got[i] = music.check_verdict(t)
			if got[i] != cc.want[i] do ok = false
		}
		fmt.printfln("  %-28s %v -> %v: %v%s", cc.name, cc.expected, cc.played, got, ok ? "" : fmt.tprintf("   <-- wanted %v", cc.want))
		if !ok do all_ok = false
		free(d)
	}
	fmt.println(all_ok ? "PASS" : "FAIL")
	if !all_ok do os.exit(1)
}
