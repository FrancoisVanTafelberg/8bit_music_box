package render

/*
    Render a song to WAV without opening a window.

        odin run tools/render -- songs/ode_to_joy.song
        odin run tools/render -- imports/fugue.mid exports/fugue.wav
        odin run tools/render -- songs/x.song out.wav -clean     (no 4-bit volume)
        odin run tools/render -- sfx cannon                      (a sound effect -> exports/cannon.wav)
        odin run tools/render -- sfx all                         (every sound effect in sounds/)

    Uses the same engine as the editor's Play and Export, so a file that sounds
    wrong here sounds wrong there, and this can be run on a machine with no
    display at all.
*/

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import music "../../source/music"

main :: proc() {
	args := os.args[1:]
	if len(args) < 1 {
		fmt.eprintln("usage: render <song.song|file.mid> [out.wav] [-clean]")
		fmt.eprintln("       render sfx <key|all> [out_dir] [-clean]")
		os.exit(2)
	}
	if args[0] == "sfx" {
		render_sound_effects(args[1:])
		return
	}
	in_path := args[0]
	out_path := ""
	crush := true
	for a in args[1:] {
		if a == "-clean" do crush = false
		else do out_path = a
	}
	if out_path == "" {
		base := in_path
		if i := strings.last_index_byte(base, '.'); i > 0 do base = base[:i]
		out_path = strings.concatenate({base, ".wav"})
	}

	// The instruments, from the .inst files - here, or beside the song's folder
	// (songs/x.song -> instruments/), whichever exists.
	reg: music.Registry
	music.registry_init(&reg)
	music.registry_bind(&reg)
	{
		dir := music.INST_DIR
		if !os.is_dir(dir) {
			d := "."
			if i := strings.last_index_any(in_path, "/\\"); i >= 0 do d = in_path[:i]
			dir = strings.concatenate({d, "/../", music.INST_DIR})
		}
		irep: music.Load_Report
		n := music.registry_load_dir(&reg, dir, &irep)
		for e in irep.errors do fmt.eprintln("instrument error:", e)
		if music.registry_ensure(&reg) do fmt.eprintln("warning: no instruments found in", dir, "- using a plain square wave")
		else do fmt.printfln("%d instruments from %s", n, dir)
	}

	song: music.Song
	music.song_init(&song)
	if strings.has_suffix(strings.to_lower(in_path, context.temp_allocator), ".mid") {
		rep := music.midi_import_file(in_path, &song)
		if rep.message != "" {
			fmt.eprintln("error:", rep.message)
			os.exit(1)
		}
		fmt.printfln("midi: %d notes in %d layers, %d moved by octaves into range", rep.notes, rep.layers, rep.transposed)
	} else {
		rep: music.Load_Report
		ok := music.song_load(in_path, &song, &rep)
		for w in rep.warnings do fmt.eprintln("warning:", w)
		for e in rep.errors do fmt.eprintln("error:", e)
		if !ok do os.exit(1)
	}

	// Every note should be one the instrument can really play.
	for &t in song.tracks {
		ins := music.inst_get(&song, t.inst)
		out := 0
		for n in t.notes {
			p := i32(music.pitch_midi(n.pitch))
			if p < ins.lo || p > ins.hi do out += 1
		}
		if out > 0 do fmt.eprintfln("warning: %s: %d of %d notes outside the %s's range", t.name, out, len(t.notes), ins.name)
	}

	t0 := time.now()
	samples := music.render_song(&song, crush)
	music.normalize(samples)
	secs := f64(len(samples) / 2) / music.SAMPLE_RATE
	fmt.printfln(
		"%s: %d layers, %.1f s of audio rendered in %.0f ms",
		song.title,
		len(song.tracks),
		secs,
		time.duration_milliseconds(time.since(t0)),
	)
	if !music.write_wav(out_path, samples) {
		fmt.eprintln("could not write", out_path)
		os.exit(1)
	}
	fmt.println("wrote", out_path)
}

// Render sound effects from sounds/ to WAV files: one key, or all of them.
render_sound_effects :: proc(args: []string) {
	which := "all"
	out_dir := "exports"
	crush := true
	n := 0
	for a in args {
		if a == "-clean" do crush = false
		else if n == 0 {which = a; n += 1} else do out_dir = a
	}
	root := "."
	if !os.is_dir(music.SFX_DIR) && os.is_dir("../" + music.SFX_DIR) do root = ".."

	m: music.Mixer
	music.mixer_init(&m)
	defer music.mixer_destroy(&m)
	rep: music.Load_Report
	ni := music.mixer_load_instruments(&m, strings.concatenate({root, "/", music.INST_DIR}), &rep)
	ns := music.mixer_load_sounds(&m, strings.concatenate({root, "/", music.SFX_DIR}), &rep)
	for w in rep.warnings do fmt.eprintln("warning:", w)
	for e in rep.errors do fmt.eprintln("error:", e)
	fmt.printfln("%d instruments, %d sound effects", ni, ns)
	if !os.is_dir(out_dir) do _ = os.make_directory(out_dir)

	found := false
	for &fx in m.sounds.list {
		if which != "all" && fx.key != which do continue
		found = true
		samples := music.render_sfx(&fx, crush)
		defer delete(samples)
		path := strings.concatenate({out_dir, "/", fx.key, ".wav"}, context.temp_allocator)
		if !music.write_wav(path, samples) {
			fmt.eprintln("could not write", path)
			os.exit(1)
		}
		fmt.printfln("%-16s %-20s %d voices, %.2f s -> %s", fx.key, fx.name, len(fx.voices), f64(len(samples) / 2) / music.SAMPLE_RATE, path)
	}
	if !found {
		fmt.eprintln("no sound effect called", which)
		os.exit(1)
	}
}
