package app

/*
    Songs on disk: where they live, opening, saving, exporting, importing.

        songs/     .song files (plain text, see DESIGN.md 5)
        imports/   .mid files to bring in
        exports/   rendered .wav, and .mp3 / .ogg / .flac through ffmpeg

    The folders sit next to wherever the app is run from - the project root
    when running build/..., found by looking for songs/ here and one level up.
*/

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "music"
import rl "vendor:raylib"

// Music that is not public domain: arrangements you may play with, never
// publish. The copy-to-repo script and .gitignore both leave this folder out.
PRIVATE_DIR :: "songs_that_cannot_be_used_for_legal_reasons"

files_init :: proc() {
	base := "."
	if !os.is_dir("songs") && os.is_dir("../songs") do base = ".."
	g.base_dir = strings.clone(base)
	for d in ([6]string{"songs", "imports", "exports", PRIVATE_DIR, music.INST_DIR, music.SFX_DIR}) {
		p := join(d)
		if !os.is_dir(p) do _ = os.make_directory(p)
	}
	when CELLO do if !os.is_dir(join(CELLO_DIR)) do _ = os.make_directory(join(CELLO_DIR))
	g.has_ffmpeg = ffmpeg_available()
}

files_destroy :: proc() {
	for f in g.open_files do delete(f)
	delete(g.open_files)
	delete(g.path)
	delete(g.base_dir)
	g.open_files = nil
	g.path = ""
	g.base_dir = ""
}

join :: proc(parts: ..string) -> string {
	all := make([dynamic]string, context.temp_allocator)
	append(&all, g.base_dir)
	append(&all, ..parts)
	return strings.join(all[:], "/", context.temp_allocator)
}

// Every .song in songs/ and every .mid in imports/, songs first.
files_scan :: proc() {
	for f in g.open_files do delete(f)
	clear(&g.open_files)
	scan :: proc(dir: string, exts: []string) {
		infos, err := os.read_directory_by_path(join(dir), -1, context.temp_allocator)
		if err != nil do return
		names := make([dynamic]string, context.temp_allocator)
		for fi in infos {
			lower := strings.to_lower(fi.name, context.temp_allocator)
			for e in exts do if strings.has_suffix(lower, e) do append(&names, fi.name)
		}
		slice.sort(names[:])
		for n in names do append(&g.open_files, strings.clone(join(dir, n)))
	}
	when CELLO do scan(CELLO_DIR, {music.SONG_EXT})
	scan("songs", {music.SONG_EXT})
	scan("imports", {".mid", ".midi"})
	scan(PRIVATE_DIR, {music.SONG_EXT, ".mid", ".midi"})
}

file_new :: proc() {
	if g.dirty && !confirmed("new", "Unsaved changes will be lost") do return
	player_stop(&g.player)
	music.song_destroy(&g.song)
	music.song_init(&g.song)
	music.song_add_track(&g.song, CELLO_KEY when CELLO else music.DEFAULT_KEY)
	set_path("")
	after_load()
	g.private = false
	set_status("new song")
}

file_open :: proc(path: string) {
	lower := strings.to_lower(path, context.temp_allocator)
	player_stop(&g.player)
	switch {
	case strings.has_suffix(lower, music.SONG_EXT):
		rep: music.Load_Report
		defer music.report_destroy(&rep)
		if !music.song_load(path, &g.song, &rep) && len(g.song.tracks) == 0 {
			set_error("%s", len(rep.errors) > 0 ? rep.errors[0] : "could not open")
			return
		}
		set_path(path)
		after_load()
		g.private = strings.contains(path, PRIVATE_DIR)
		if g.cello_notice {
			// cello_only() has already said what it changed.
		} else if len(rep.errors) > 0 {
			set_error("opened with %d problem(s): %s", len(rep.errors), rep.errors[0])
		} else if len(rep.warnings) > 0 {
			set_status("opened %s (%d warning(s): %s)", path, len(rep.warnings), rep.warnings[0])
		} else {
			set_status("opened %s", path)
		}
		remember_last(path)
	case strings.has_suffix(lower, ".mid"), strings.has_suffix(lower, ".midi"):
		private := strings.contains(path, PRIVATE_DIR)
		rep := music.midi_import_file(path, &g.song)
		if rep.message != "" {
			set_error("MIDI import failed: %s", rep.message)
			delete(rep.message)
			return
		}
		// An import is a new song: saving it writes a .song, not over the .mid.
		set_path("")
		after_load()
		g.private = private
		g.dirty = true
		if !g.cello_notice do set_status(
			"imported %d notes into %d layers%s - Save to keep it as a .song",
			rep.notes,
			rep.layers,
			rep.transposed > 0 ? fmt.tprintf(" (%d moved by octaves into range)", rep.transposed) : "",
		)
	case strings.has_suffix(lower, ".wav"), strings.has_suffix(lower, ".mp3"), strings.has_suffix(lower, ".ogg"), strings.has_suffix(lower, ".flac"):
		set_error("audio -> notes is not in this build yet (DESIGN.md 8); convert to .mid first")
	case:
		set_error("don't know how to open %s", path)
	}
}

@(private = "file")
after_load :: proc() {
	g.cello_notice = false
	g.ratio_ref = -1
	g.cursor_tick = 0
	input_reset()
	when CELLO do cello_only()
	music.song_fit_bars(&g.song, BARS_PER_PAGE)
	g.active = 0
	metronome_sync() // on top, so the first real layer is 1
	g.page = 0
	g.selected = -1
	g.layer_scroll = 0
	g.dirty = false
	undo_clear()
}

@(private = "file")
set_path :: proc(p: string) {
	// Clone before freeing: `p` is often g.path itself.
	fresh := strings.clone(p)
	delete(g.path)
	g.path = fresh
}

// "Ode to Joy (Beethoven)" -> "ode_to_joy_beethoven"
slug :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	last_us := true
	for c in transmute([]u8)s {
		ch := c
		if ch >= 'A' && ch <= 'Z' do ch += 32
		if (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') {
			strings.write_byte(&b, ch)
			last_us = false
		} else if !last_us {
			strings.write_byte(&b, '_')
			last_us = true
		}
	}
	out := strings.trim_right(strings.to_string(b), "_")
	return len(out) > 0 ? out : "untitled"
}

file_save :: proc() {
	path := g.path
	if path == "" {
		dir := g.private ? PRIVATE_DIR : ("songs" when !CELLO else CELLO_DIR)
		path = join(dir, strings.concatenate({slug(g.song.title), music.SONG_EXT}, context.temp_allocator))
	}
	when CELLO {
		// Opened from songs/: save a cello copy in cello_songs/, never over
		// the original (its layers were other instruments).
		if !g.private && !strings.contains(path, CELLO_DIR) {
			name := path
			if k := strings.last_index_any(name, "/\\"); k >= 0 do name = name[k + 1:]
			path = join(CELLO_DIR, name)
		}
	}
	if !music.song_save(&g.song, path) {
		set_error("could not write %s", path)
		return
	}
	set_path(path)
	g.dirty = false
	remember_last(path)
	set_status("saved %s", path)
}

// The name exports get: the song file's name, or the title's slug.
@(private = "file")
export_base :: proc() -> string {
	name := slug(g.song.title)
	if g.path != "" {
		name = g.path
		if k := strings.last_index_any(name, "/\\"); k >= 0 do name = name[k + 1:]
		if k := strings.last_index_byte(name, '.'); k > 0 do name = name[:k]
	}
	return join("exports", name)
}

file_export :: proc(format: string) {
	wav := strings.concatenate({export_base(), ".wav"}, context.temp_allocator)
	// Not the metronome's clicks: they are for practising, not the song.
	held: [dynamic]music.Note
	for &t in g.song.tracks do if t.metronome {held = t.notes; t.notes = {}}
	samples := music.render_song(&g.song, g.mode)
	for &t in g.song.tracks do if t.metronome do t.notes = held
	defer delete(samples)
	music.normalize(samples)
	if !music.write_wav(wav, samples) {
		set_error("could not write %s", wav)
		return
	}
	if format == "wav" {
		set_status("exported %s  (%.1f s)", wav, f64(len(samples) / 2) / music.SAMPLE_RATE)
		return
	}
	out := strings.concatenate({export_base(), ".", format}, context.temp_allocator)
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "ffmpeg", "-y", "-loglevel", "error", "-i", wav)
	switch format {
	case "mp3":
		append(&args, "-codec:a", "libmp3lame", "-q:a", "2")
	case "ogg":
		append(&args, "-codec:a", "libvorbis", "-q:a", "6")
	}
	append(&args, out)
	state, _, stderr, err := os.process_exec({command = args[:]}, context.temp_allocator)
	if err != nil || state.exit_code != 0 {
		msg := strings.trim_space(string(stderr))
		set_error("ffmpeg failed: %s", len(msg) > 0 ? msg : fmt.tprintf("%v", err))
		return
	}
	set_status("exported %s", out)
}

@(private = "file")
ffmpeg_available :: proc() -> bool {
	state, _, _, err := os.process_exec({command = {"ffmpeg", "-version"}}, context.temp_allocator)
	return err == nil && state.exited && state.exit_code == 0
}

// Anything dragged onto the window: open it.
files_poll_dropped :: proc() {
	if !rl.IsFileDropped() do return
	files := rl.LoadDroppedFiles()
	defer rl.UnloadDroppedFiles(files)
	if files.count == 0 do return
	path := strings.clone(string(files.paths[0]), context.temp_allocator)
	if g.dirty && !confirmed(path, "Unsaved changes will be lost - drop it again") do return
	file_open(path)
}

// ---------------------------------------------------------------------------
// Reopen what was open last time.
// ---------------------------------------------------------------------------

@(private = "file")
remember_last :: proc(path: string) {
	_ = os.write_entire_file(join(LAST_SONG_FILE), path)
}

open_last_song :: proc() -> bool {
	candidates := make([dynamic]string, context.temp_allocator)
	if data, err := os.read_entire_file_from_path(join(LAST_SONG_FILE), context.temp_allocator); err == nil {
		append(&candidates, strings.trim_space(string(data)))
	}
	// Otherwise the first song in songs/, whatever it has been renamed to.
	files_scan()
	for f in g.open_files do if strings.has_suffix(f, music.SONG_EXT) do append(&candidates, f)
	for c in candidates {
		if c == "" || !os.is_file(c) do continue
		file_open(c)
		if len(g.song.tracks) > 0 do return true
	}
	return false
}

// ---------------------------------------------------------------------------
// Instrument files
// ---------------------------------------------------------------------------

// Read the .inst files in instruments/: the whole orchestra, into the mixer.
// At startup (`first`) and on F7 alike the files are read over what is there,
// so every instrument a track points at stays where it is. The sound effects in
// sounds/ are reloaded with them (the editor does not play them, but a broken
// .sfx file shows up here).
instruments_reload :: proc(first: bool) {
	music.mixer_bind(&g.audio)
	rep: music.Load_Report
	defer music.report_destroy(&rep)
	n := music.registry_load_dir(&g.audio.reg, join(music.INST_DIR), &rep)
	if music.registry_ensure(&g.audio.reg) {
		set_error("no instruments found in %s/ - playing everything as a square wave", join(music.INST_DIR))
		return
	}
	fx := music.mixer_load_sounds(&g.audio, join(music.SFX_DIR), &rep)
	switch {
	case len(rep.errors) > 0:
		set_error("instruments: %d problem(s) - %s", len(rep.errors), rep.errors[0])
	case len(rep.warnings) > 0:
		set_status("instruments: %d from files (%s)", n, rep.warnings[0])
	case !first:
		set_status("reloaded: %d instruments from instruments/, %d sound effects from sounds/", n, fx)
	}
}

// The Cello Helper plays nothing but cellos: every layer of a song that
// opens here becomes a cello layer. Notes the cello cannot reach stay where
// they are, drawn in red, and are counted in the status line.
cello_only :: proc() {
	cello := music.inst_or_default(&g.song, CELLO_KEY)
	changed, out := 0, 0
	ins := music.inst_get(&g.song, cello)
	for &t in g.song.tracks {
		if t.metronome do continue
		if t.inst != cello {
			was := music.inst_get(&g.song, t.inst).name
			name := fmt.aprintf("Cello (was %s)", t.name != "" ? t.name : was)
			delete(t.name)
			t.name = name
			t.inst = cello
			changed += 1
		}
		for n in t.notes {
			m := i32(music.pitch_midi(n.pitch))
			if m < ins.lo || m > ins.hi do out += 1
		}
	}
	if changed > 0 || out > 0 {
		set_error("%d layer(s) turned into cellos%s - Save keeps this as a copy in %s/", changed, out > 0 ? fmt.tprintf(", %d note(s) outside the cello's range (red)", out) : "", CELLO_DIR)
		g.cello_notice = true
	}
}
