package app

/*
    Import audio: a recording (.wav, or .mp4 / .mp3 / .m4a / .ogg / .flac /
    .webm through ffmpeg) in, a draft song out - one layer per voice per
    instrument. The hearing itself is music/audio_import.odin; this is the
    window it is set up in and the progress bar it runs behind.

        open or drop the file  ->  the Import audio window: voices, the two
        instruments, tempo, time, grid, the notes to listen for  ->
        Transcribe  ->  a few seconds a minute of music, a slice per frame
        ->  the draft, as a new unsaved song (Save puts it with the private
        songs: a recording is usually of someone else's music)
*/

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "music"
import rl "vendor:raylib"

AUDIO_EXTS := [?]string{".wav", ".mp4", ".m4a", ".mp3", ".ogg", ".flac", ".webm", ".aac", ".opus"}
AUDIO_MAX_SECONDS :: 20 * 60

Audio_Import_UI :: struct {
	path:    string, // the recording (owned)
	title:   string, // the song's title: the file's name (owned)
	samples: []f32, // mono, decoded (owned)
	rate:    int,
	opts:    music.Audio_Import_Options,
	job:     music.Audio_Import,
	running: bool,
	started: f64,
}

is_audio_file :: proc(path: string) -> bool {
	lower := strings.to_lower(path, context.temp_allocator)
	for e in AUDIO_EXTS do if strings.has_suffix(lower, e) do return true
	return false
}

audio_import_close :: proc() {
	a := &g.audio_import
	music.audio_import_destroy(&a.job)
	delete(a.samples)
	delete(a.path)
	delete(a.title)
	opts := a.opts
	a^ = {}
	a.opts = opts // the settings stay for the next recording
}

// Open a recording: decode it and show the Import audio window.
audio_import_open :: proc(path: string) {
	audio_import_close()
	a := &g.audio_import
	if a.opts.voices == 0 do a.opts = music.audio_import_defaults()
	lower := strings.to_lower(path, context.temp_allocator)
	samples: []f32
	rate: int
	ok: bool
	if strings.has_suffix(lower, ".wav") do samples, rate, ok = music.wav_read(path)
	// Anything else - or a .wav in a coding wav_read does not know - by
	// ffmpeg, to a plain mono .wav at the rate the hearing works at.
	if !ok {
		if !g.has_ffmpeg {
			set_error("%s needs ffmpeg to read (it is not on the PATH) - or convert it to .wav", path)
			return
		}
		tmp := join("exports", "_audio_import.wav")
		cmd := []string{"ffmpeg", "-y", "-loglevel", "error", "-i", path, "-vn", "-ac", "1", "-ar", fmt.tprint(music.PITCH_RATE), "-c:a", "pcm_s16le", tmp}
		state, _, stderr, err := os.process_exec({command = cmd}, context.temp_allocator)
		if err != nil || state.exit_code != 0 {
			msg := strings.trim_space(string(stderr))
			set_error("ffmpeg could not read %s: %s", path, len(msg) > 0 ? msg : fmt.tprintf("%v", err))
			return
		}
		samples, rate, ok = music.wav_read(tmp)
		_ = os.remove(tmp)
		if !ok {
			set_error("could not read the sound in %s", path)
			return
		}
	}
	seconds := f32(len(samples)) / f32(max(rate, 1))
	if seconds < 1 || seconds > AUDIO_MAX_SECONDS {
		delete(samples)
		set_error("%s is %.0f s long: audio import takes 1 s to %d minutes", path, seconds, AUDIO_MAX_SECONDS / 60)
		return
	}
	a.samples = samples
	a.rate = rate
	a.path = strings.clone(path)
	name := path
	if k := strings.last_index_any(name, "/\\"); k >= 0 do name = name[k + 1:]
	if k := strings.last_index_byte(name, '.'); k > 0 do name = name[:k]
	a.title = strings.clone(name)
	g.overlay = .Audio_Import
	set_status("%s: %.0f s of sound - choose how to hear it, then Transcribe", name, seconds)
}

// Transcribe: start hearing it (a slice a frame, audio_import_update).
audio_import_start :: proc() {
	a := &g.audio_import
	music.audio_import_begin(&a.job, a.samples, a.rate, a.opts)
	a.running = true
	a.started = rl.GetTime()
}

// Every frame: a slice of the hearing, about 25 ms of work, so the window
// keeps drawing and the progress bar moves.
audio_import_update :: proc() {
	a := &g.audio_import
	// The window was closed (Esc, a click outside): stop, and let the
	// recording go.
	if g.overlay != .Audio_Import {
		if a.running do set_status("audio import stopped")
		if a.samples != nil do audio_import_close()
		return
	}
	if !a.running do return
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < 25 {
		if music.audio_import_step(&a.job, music.CHORD_HOP * 16) {
			audio_import_finish()
			return
		}
	}
}

@(private = "file")
audio_import_finish :: proc() {
	a := &g.audio_import
	took := rl.GetTime() - a.started
	tempo := a.job.tempo
	notes, layers := file_from_audio(&a.job, a.title)
	set_status(
		"%s: %d notes in %d layers, %.0f bpm%s, in %.0f s - a draft to check by ear; Save puts it with the private songs",
		a.title,
		notes,
		layers,
		tempo,
		a.opts.tempo > 0 ? "" : " (guessed)",
		took,
	)
	g.overlay = .None
	audio_import_close()
}

// The instruments to choose from: everything that plays notes (not drums).
@(private = "file")
inst_cycle :: proc(key: string, dir: int, allow_none: bool) -> string {
	keys := make([dynamic]string, context.temp_allocator)
	if allow_none do append(&keys, "")
	for ins in music.reg().list do if ins.family != .Percussion do append(&keys, ins.key)
	if len(keys) == 0 do return key
	at := 0
	for k, i in keys do if k == key do at = i
	return keys[(at + dir + len(keys)) % len(keys)]
}

@(private = "file")
inst_label :: proc(key: string) -> string {
	if key == "" do return "(none)"
	if id, ok := music.registry_find(music.reg(), key); ok {
		ins := music.reg().list[id]
		return fmt.tprintf("%s  %s-%s", ins.name, midi_name(int(ins.lo)), midi_name(int(ins.hi)))
	}
	return key
}

audio_import_draw :: proc() {
	a := &g.audio_import
	o := &a.opts
	W, H := f32(600), f32(338)
	r := rect((screen_w() - W) / 2, (screen_h() - H) / 2, W, H)
	fill(rect(0, 0, screen_w(), screen_h()), COL_SCRIM)
	fill(r, COL_PANEL)
	outline(r, COL_ACCENT)
	x := r.x + 14
	y := r.y + 10
	text("Import audio", x, y, COL_TEXT, FONT_BIG)
	secs := f32(len(a.samples)) / f32(max(a.rate, 1))
	text(fmt.tprintf("%s   %d:%02d", fit_text(a.title, W - 220), int(secs) / 60, int(secs) % 60), x + 150, y + 6, COL_DIM)
	y += 30
	text("A draft, not a finished transcription: the notes it is sure of, in time, to correct on the sheet.", x, y, COL_FAINT)
	y += 14
	text("Best on one instrument, recorded close. A full band or a mix with drums comes out a tangle.", x, y, COL_FAINT)
	y += 24

	busy := a.running
	LX :: f32(150) // where the controls start
	row :: proc(name, hint: string, x, y: f32) {
		text(name, x, y + 4, COL_DIM)
		if hint != "" do text(hint, x + 150 + 236, y + 4, COL_FAINT)
	}
	// While it listens the settings are shown, not changed.
	fixed :: proc(r: rl.Rectangle, s: string) {
		fill(r, COL_SHEET)
		text_centered(s, r, COL_DIM)
	}

	// Voices.
	row("voices", o.voices == 1 ? "a melody: the note, not its overtones" : "up to this many at once: one layer each", x, y)
	if !busy do o.voices = int(stepper(rect(x + LX, y, 120, 18), f32(o.voices), 1, music.AUDIO_IMPORT_MAX_VOICES, 1, 1, fmt.tprint(o.voices)))
	else do fixed(rect(x + LX, y, 120, 18), fmt.tprint(o.voices))
	y += 24

	// The instruments: each voice is written for each.
	for k in 0 ..< music.AUDIO_IMPORT_MAX_INSTS {
		row(k == 0 ? "for" : "and for", k == 0 ? "each voice, moved by octaves into its range" : "each voice twice: practise it on either", x, y)
		if button(rect(x + LX, y, 18, 18), "<", false, !busy) do o.insts[k] = inst_cycle(o.insts[k], -1, k > 0)
		fill(rect(x + LX + 18, y, 192, 18), COL_SHEET)
		text_centered(fit_text(inst_label(o.insts[k]), 188), rect(x + LX + 18, y, 192, 18))
		if button(rect(x + LX + 210, y, 18, 18), ">", false, !busy) do o.insts[k] = inst_cycle(o.insts[k], 1, k > 0)
		y += 22
	}
	y += 4

	// Time.
	row("tempo", o.tempo == 0 ? "guessed from where the notes fall" : "beats a minute (right-click: guess)", x, y)
	tempo_s := o.tempo == 0 ? "auto" : fmt.tprintf("%.0f", o.tempo)
	if !busy do o.tempo = stepper(rect(x + LX, y, 120, 18), o.tempo, 0, 300, 1, 0, tempo_s)
	else do fixed(rect(x + LX, y, 120, 18), tempo_s)
	y += 22
	row("time", "where the bar lines go", x, y)
	if !busy {
		o.beats = i32(stepper(rect(x + LX, y, 80, 18), f32(o.beats), 1, 16, 1, 4, fmt.tprint(o.beats)))
		text("/", x + LX + 86, y + 4, COL_DIM)
		if button(rect(x + LX + 98, y, 30, 18), fmt.tprint(o.beat_unit)) do o.beat_unit = o.beat_unit == 4 ? 8 : (o.beat_unit == 8 ? 2 : 4)
	} else do fixed(rect(x + LX, y, 128, 18), fmt.tprintf("%d / %d", o.beats, o.beat_unit))
	y += 22
	row("snap to", "every start and end, to this grid", x, y)
	GRIDS := [?]i32{12, 6, 3, 8}
	GRID_NAMES := [?]string{"8th", "16th", "32nd", "8th triplet"}
	gx := x + LX
	for gr, i in GRIDS {
		w := f32(i == 3 ? 82 : 46)
		if button(rect(gx, y, w, 18), GRID_NAMES[i], o.grid == gr, !busy) do o.grid = gr
		gx += w + 4
	}
	y += 26

	// What to listen for.
	row("listen from", "the lowest and highest notes looked for", x, y)
	if !busy {
		o.lo = stepper(rect(x + LX, y, 100, 18), o.lo, 24, o.hi - 12, 1, 28, midi_name(int(o.lo)))
		o.hi = stepper(rect(x + LX + 110, y, 100, 18), o.hi, o.lo + 12, 108, 1, 96, midi_name(int(o.hi)))
	} else do fixed(rect(x + LX, y, 210, 18), fmt.tprintf("%s - %s", midi_name(int(o.lo)), midi_name(int(o.hi))))
	y += 22
	row("ignore noise", "above the recording's quietest moment", x, y)
	if !busy do o.sensitivity = stepper(rect(x + LX, y, 120, 18), o.sensitivity, 1, 10, 0.5, music.PITCH_SENSITIVITY_DEFAULT, fmt.tprintf("x%.1f", o.sensitivity))
	else do fixed(rect(x + LX, y, 120, 18), fmt.tprintf("x%.1f", o.sensitivity))
	y += 30

	// Go, or how far it has got.
	if busy {
		p := music.audio_import_progress(&a.job)
		bar := rect(x, y, W - 28 - 100, 22)
		fill(bar, COL_SHEET)
		fill(rect(bar.x, bar.y, bar.width * p, bar.height), with_alpha(COL_ACCENT, 160))
		outline(bar, COL_EDGE)
		text_centered(fmt.tprintf("listening... %.0f%%   %d notes so far", p * 100, len(a.job.notes)), bar)
		if button(rect(r.x + W - 14 - 90, y, 90, 22), "Stop") {
			audio_import_close()
			g.overlay = .None
			set_status("audio import stopped")
		}
	} else {
		if button(rect(x, y, 140, 22), "Transcribe", true) {
			if !g.dirty || confirmed("audio import", "Unsaved changes will be lost") do audio_import_start()
		}
		if button(rect(x + 150, y, 90, 22), "Cancel") {
			audio_import_close()
			g.overlay = .None
		}
		text("Esc closes", x + 252, y + 5, COL_FAINT)
	}
	if hovered(r) do ui_take_all()
}
