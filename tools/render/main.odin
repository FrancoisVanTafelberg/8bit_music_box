package render

/*
    Render a song to WAV without opening a window.

        odin run tools/render -- songs/ode_to_joy.song
        odin run tools/render -- imports/fugue.mid exports/fugue.wav
        odin run tools/render -- songs/x.song out.wav -clean     (no 4-bit volume)

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
		os.exit(2)
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
