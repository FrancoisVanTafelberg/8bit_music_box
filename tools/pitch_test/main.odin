package pitch_test

/*
    Checks the input mode's pitch detection (source/music/pitch.odin) without
    a microphone: a cello part is rendered with the app's own engine (32-bit,
    the bowed-string model), noise of a room is added - hiss, mains hum, a
    fan's rumble, a murmur of voices - and the result is fed to the detector
    as a mic would feed it. Prints how often each note was read right, and
    whether anything was read where nothing was played.

        odin run tools/pitch_test
        odin run tools/pitch_test -- out.wav        (also writes what was fed in)
        odin run tools/pitch_test -- -noisy         (the room 12 dB louder)
*/

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import music "../../source/music"

Expect :: struct {
	start, end: f64, // seconds
	midi:       int,
}

main :: proc() {
	reg: music.Registry
	music.registry_init(&reg)
	music.registry_bind(&reg)
	irep: music.Load_Report
	music.registry_load_dir(&reg, music.INST_DIR, &irep)
	music.registry_ensure(&reg)

	// The part: open strings, a scale up the A string, low and high notes,
	// a leap, repeated notes.
	notes := [?][2]int {
		{36, 2}, {43, 2}, {50, 2}, {57, 2}, // C2 G2 D3 A3, half notes
		{57, 1}, {59, 1}, {61, 1}, {62, 1}, {64, 1}, {66, 1}, {68, 1}, {69, 1}, // A major up the A string
		{38, 2}, {74, 2}, {41, 1}, {41, 1}, {79, 2}, {84, 2}, // D2, D5, F2 F2, G5, C6
	}
	song: music.Song
	music.song_init(&song)
	song.tempo = 90
	ti := music.song_add_track(&song, "cello")
	lead_in := i32(2 * music.TPQ * 4) // two bars of room noise first: the gate learns the room
	tick := lead_in
	expect := make([dynamic]Expect)
	spt := music.tick_seconds(&song)
	for n in notes {
		ln := i32(n[1]) * music.TPQ
		append(&song.tracks[ti].notes, music.Note{tick, ln, music.pitch_from_midi(n[0], 0), 100})
		append(&expect, Expect{f64(tick) * spt, f64(tick + ln) * spt, n[0]})
		tick += ln
	}
	// Three silent beats at the end: only the room.
	song.bars = (tick + 3 * music.TPQ) / music.bar_ticks(&song) + 2

	// -noisy: the room four times louder (12 dB).
	noise := f32(1)
	wav := ""
	for a in os.args[1:] {if a == "-noisy" do noise = 4; else do wav = a}
	all_ok := true
	for mode in ([2]music.Sound_Mode{.Bit32, .Bit16}) {
		stereo := music.render_song(&song, mode)
		// To the mic's rate, mono (a pair of samples averaged: good enough
		// ahead of the detector's own low-pass).
		n := len(stereo) / 4
		tail := int(3 * f64(music.TPQ) * spt * music.PITCH_RATE)
		mic := make([]f32, n + tail)
		for i in 0 ..< n {
			k := i * 4
			mic[i] = (stereo[k] + stereo[k + 1] + stereo[k + 2] + stereo[k + 3]) * 0.25
		}
		// The note's level: normalise the part to a mic's -12 dBFS peak.
		peak: f32
		for s in mic do peak = max(peak, abs(s))
		for &s in mic do s *= 0.25 / max(peak, 1e-6)

		// The room: hiss at -46 dBFS, 50 Hz hum and its harmonics, a fan's
		// rumble, and a murmur of voices (noise shaped to the speech band,
		// swelling and fading).
		rng := rand.create(1234)
		context.random_generator = rand.default_random_generator(&rng)
		rumble, voice1, voice2: f32
		for i in 0 ..< len(mic) {
			t := f32(i) / music.PITCH_RATE
			w := rand.float32_range(-1, 1)
			hiss := w * 0.005
			hum := 0.006 * math.sin(2 * math.PI * 50 * t) + 0.003 * math.sin(2 * math.PI * 150 * t)
			rumble += (rand.float32_range(-1, 1) - rumble) * 0.01
			voice1 += (rand.float32_range(-1, 1) - voice1) * 0.12
			voice2 += (voice1 - voice2) * 0.3
			murmur := (voice1 - voice2) * 0.02 * (0.6 + 0.4 * math.sin(2 * math.PI * 0.7 * t))
			mic[i] += (hiss + hum + rumble * 0.05 + murmur) * noise
		}

		if wav != "" && mode == .Bit32 do write_wav(wav, mic)

		// Feed it as the mic would: 512 samples at a time.
		d: music.Pitch_Detector
		music.pitch_init(&d, 36, 84) // the cello, C2 - C6
		out: [8]music.Pitch_Reading
		right := make([]int, len(expect))
		seen := make([]int, len(expect))
		false_hits, silent_reads := 0, 0
		cents_sum, cents_n: f64
		for at := 0; at < len(mic); at += 512 {
			chunk := mic[at:min(at + 512, len(mic))]
			k := music.pitch_feed(&d, chunk, out[:])
			for r in out[:k] {
				t := f64(at + len(chunk) - r.delay) / music.PITCH_RATE
				which := -1
				for e, i in expect do if t >= e.start + 0.08 && t < e.end - 0.05 do which = i
				between := true
				for e in expect do if t >= e.start - 0.05 && t < e.end + 0.35 do between = false
				if which >= 0 {
					seen[which] += 1
					if r.midi > 0 && int(math.round(r.midi)) == expect[which].midi {
						right[which] += 1
						cents_sum += abs(f64(r.midi) - f64(expect[which].midi)) * 100
						cents_n += 1
					}
				} else if between {
					silent_reads += 1
					if r.midi > 0 do false_hits += 1
				}
			}
		}
		fmt.printfln("--- %v: %.1f s fed, %d analyses", mode, f64(len(mic)) / music.PITCH_RATE, d.analyses)
		total_r, total_s := 0, 0
		for e, i in expect {
			pct := seen[i] > 0 ? 100 * right[i] / seen[i] : 0
			fmt.printfln("  %-4s  %3d%% of %2d readings right%s", music.pitch_name_temp(music.pitch_from_midi(e.midi, 0)), pct, seen[i], pct < (noise > 1 ? 75 : 85) ? "   <-- low" : "")
			total_r += right[i]
			total_s += seen[i]
			if pct < (noise > 1 ? 75 : 85) do all_ok = false
		}
		fmt.printfln("  overall %d%%, mean error %.1f cents", 100 * total_r / max(total_s, 1), cents_sum / max(cents_n, 1))
		fmt.printfln("  room noise only: %d of %d readings called a note", false_hits, silent_reads)
		if false_hits > silent_reads / 50 do all_ok = false
	}
	fmt.println(all_ok ? "PASS" : "FAIL")
	if !all_ok do os.exit(1)
}

write_wav :: proc(path: string, mono: []f32) {
	st := make([]f32, len(mono) * 2)
	for s, i in mono {st[2 * i] = s; st[2 * i + 1] = s}
	// write_wav writes at the engine's rate: repeat each sample to get there.
	up := make([]f32, len(st) * 2)
	for i in 0 ..< len(mono) {
		for k in 0 ..< 4 do up[i * 4 + k] = mono[i]
	}
	music.write_wav(path, up)
}
