package audio_test

/*
    Checks audio import (source/music/audio_import.odin) on recordings whose
    notes are known: public-domain songs from songs/, a part or two rendered
    with the app's own engine, written to a .wav and read back (so wav_read is
    tested too), then imported.

    For each: how many of the real notes were heard (the right pitch, starting
    within 70 ms), how many heard notes are not real, the tempo guessed against
    the real one, the key signature guessed (sharps +, flats -) against the
    real one, and - with the tempo given - how many notes land on the
    right tick in the draft song.

        odin run tools/audio_test -o:speed
        odin run tools/audio_test -o:speed -- -v       (every miss)
        odin run tools/audio_test -o:speed -- -noisy   (hiss, hum and an echo added)
*/

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:time"
import music "../../source/music"

Case :: struct {
	song:   string,
	parts:  []string, // the layers to render (the rest are left out)
	voices: int,
}

CASES := []Case {
	{"songs/ode_to_joy.song", {"Violin"}, 1},
	{"songs/ode_to_joy.song", {"Cello"}, 1},
	{"songs/ode_to_joy.song", {"Flute"}, 1},
	{"songs/road_to_boston.song", {"Fife 1"}, 1},
	{"songs/british_grenadiers.song", {"Fife 1"}, 1},
	{"songs/road_to_boston.song", {"Trumpet"}, 1},
	{"songs/and_william_beat_to_quarters.song", {"Violin"}, 1},
	{"songs/musica_notturna_madrid.song", {"Cello"}, 1},
	{"songs/ode_to_joy.song", {"Violin", "Cello"}, 2},
	{"songs/and_william_beat_to_quarters.song", {"Violin", "Cello"}, 4}, // cello chords
}

main :: proc() {
	reg: music.Registry
	music.registry_init(&reg)
	music.registry_bind(&reg)
	irep: music.Load_Report
	music.registry_load_dir(&reg, music.INST_DIR, &irep)
	music.registry_ensure(&reg)

	verbose := false
	noisy := false
	for a in os.args[1:] {
		if a == "-v" do verbose = true
		if a == "-noisy" do noisy = true
	}

	total_real, total_found, total_heard, total_false, total_tick := 0, 0, 0, 0, 0
	fmt.printfln("%-46s %6s %8s %8s %12s %8s %8s %7s", "case", "notes", "heard", "false", "tempo", "key", "on tick", "ms/s")
	for c in CASES {
		song: music.Song
		rep: music.Load_Report
		if !music.song_load(c.song, &song, &rep) {
			fmt.eprintln("could not load", c.song)
			os.exit(1)
		}
		// Only the parts asked for.
		for i := len(song.tracks) - 1; i >= 0; i -= 1 {
			keep := false
			for p in c.parts do if song.tracks[i].name == p do keep = true
			if !keep {
				music.track_destroy(&song.tracks[i])
				ordered_remove(&song.tracks, i)
			}
		}
		// The real notes, in seconds, and which voice (layer order = voice).
		spt := f32(music.tick_seconds(&song))
		Real :: struct {
			t, end: f32,
			midi:   int,
			tick:   i32,
			voice:  int,
		}
		real: [dynamic]Real
		for t, v in song.tracks do for n in t.notes {
			append(&real, Real{f32(n.tick) * spt, f32(n.tick + n.len) * spt, music.pitch_midi(n.pitch), n.tick, v})
		}

		// Render, to WAV and back.
		stereo := music.render_song(&song)
		music.normalize(stereo)
		path := "exports/_audio_test.wav"
		if !music.write_wav(path, stereo) {
			fmt.eprintln("could not write", path)
			os.exit(1)
		}
		delete(stereo)
		samples, rate, ok := music.wav_read(path)
		// A room: hiss and mains hum 30 dB down, and a little echo.
		if noisy && ok {
			echo := rate / 9
			for i := len(samples) - 1; i >= echo; i -= 1 do samples[i] += samples[i - echo] * 0.3
			for &s, i in samples {
				s += (rand.float32() * 2 - 1) * 0.02 + 0.02 * math.sin(f32(i) * math.TAU * 50 / f32(rate))
			}
		}
		if !ok {
			fmt.eprintln("wav_read failed on", path)
			os.exit(1)
		}

		// Import, tempo guessed.
		opts := music.audio_import_defaults()
		opts.voices = c.voices
		job: music.Audio_Import
		start := time.now()
		music.audio_import_begin(&job, samples, rate, opts)
		for !music.audio_import_step(&job, music.PITCH_RATE) {}
		took := time.duration_seconds(time.since(start))
		secs := music.audio_import_length(&job)

		// Heard against real: the right pitch, starting within 70 ms.
		used := make([]bool, len(job.notes))
		found := 0
		for r in real {
			hit := false
			for h, i in job.notes {
				if used[i] || int(math.round(h.midi)) != r.midi || abs(h.start - r.t) > 0.07 do continue
				used[i] = true
				hit = true
				break
			}
			if hit do found += 1
			else if verbose do fmt.printfln("    missed %3d at %6.2f s (%d ticks)", r.midi, r.t, r.tick)
		}
		false_n := 0
		for u, i in used do if !u {
			false_n += 1
			if verbose do fmt.printfln("    false  %5.1f at %6.2f s, %.2f s long", job.notes[i].midi, job.notes[i].start, job.notes[i].end - job.notes[i].start)
		}
		guessed := job.tempo

		// The draft with the real tempo: on the right tick (allowing the
		// grid's start to be off by whole bars - it cannot know the pickup).
		music.audio_import_destroy(&job)
		opts.tempo = song.tempo
		opts.insts = {song.tracks[0].name == "Cello" ? "cello" : music.reg().list[song.tracks[0].inst].key, ""}
		music.audio_import_begin(&job, samples, rate, opts)
		for !music.audio_import_step(&job, 1 << 30) {}
		draft: music.Song
		music.audio_import_song(&job, &draft, "draft")
		on_tick := 0
		key_s := fmt.tprintf("%v (%v)", draft.key, song.key)
		{
			// The shift (in grid steps) that lines up the most notes.
			// (The draft starts at its first note; the part may come in later.)
			first := real[0].tick
			for r in real do first = min(first, r.tick)
			best := 0
			for shift := first - 96; shift <= first + 96; shift += 6 {
				k := 0
				for r in real {
					hit: for t in draft.tracks do for n in t.notes {
						if n.tick + shift == r.tick && music.pitch_midi(n.pitch) % 12 == r.midi % 12 {k += 1; break hit}
					}
				}
				best = max(best, k)
			}
			on_tick = best
		}
		music.song_destroy(&draft)

		label := fmt.tprintf("%s %v", c.song[6:len(c.song) - 5], c.parts)
		// (Each figure made a string first: a width on a number pads it with
		// zeros in this Odin.)
		fmt.printfln(
			"%-46s %6s %8s %8s %12s %8s %8s %7s",
			label,
			fmt.tprint(len(real)),
			fmt.tprintf("%.0f%%", 100 * f32(found) / f32(max(len(real), 1))),
			fmt.tprint(false_n),
			fmt.tprintf("%.0f (%v)", guessed, song.tempo),
			key_s,
			fmt.tprintf("%.0f%%", 100 * f32(on_tick) / f32(max(len(real), 1))),
			fmt.tprintf("%.1f", 1000 * took / f64(secs)),
		)
		total_real += len(real)
		total_found += found
		total_heard += len(job.notes)
		total_false += false_n
		total_tick += on_tick
		music.audio_import_destroy(&job)
		delete(samples)
		delete(used)
		delete(real)
		music.song_destroy(&song)
	}
	os.remove("exports/_audio_test.wav")
	fmt.printfln(
		"\nall: %d of %d notes heard (%.0f%%), %d false, %.0f%% on the right tick",
		total_found,
		total_real,
		100 * f32(total_found) / f32(total_real),
		total_false,
		100 * f32(total_tick) / f32(total_real),
	)
}
