package app

/*
    Hot-reload boundary, and the frame.

    Same arrangement as Animal Kingdoms' game.odin: the app is a shared library,
    every piece of state lives in ONE heap block (`g`), and the host hands that
    block back after swapping the library - so you can change how a note is
    drawn, rebuild, and keep editing the song that is open, even mid-playback.

    The one rule that makes this work: NO OTHER GLOBAL STATE. Package-level
    variables are reinitialised on reload. The instrument table and the colour
    constants are fine, because they are rebuilt identically; anything that
    changes at runtime goes in App.
*/

import "core:fmt"
import "music"
import music_rl "music_rl"
import "rlu"
import rl "vendor:raylib"

App :: struct {
	v:          rlu.Virtual,
	song:       music.Song,
	// Where the song lives on disk; "" until it is first saved or loaded.
	path:       string,
	dirty:      bool,
	// Came from the not-public-domain folder: saves go back there, never to
	// songs/, so an import cannot leak into the repo by being saved.
	private:    bool,
	// Cello Helper: the song just opened had layers turned into cellos, and
	// the status line says so (not overwritten by "opened ...").
	cello_notice: bool,
	// Cello Helper: the fingerboard's key filter. Off = every position.
	fb_filter:  bool,
	fb_key:     i8,
	fb_hand:    i8, // index into HAND_POSITIONS
	// All the sound: the instruments (from instruments/), the playing song,
	// the note previews. The same Mixer a game would use; see music/mixer.odin.
	audio:      music.Mixer,
	// ...and its way out to the speakers.
	out:        music_rl.Output,
	base_dir:   string,
	has_ffmpeg: bool,

	// Editing
	active:     int, // the layer (track) being edited
	page:       i32,
	length:     music.Length,
	mod:        music.Length_Mod,
	acc_mode:   Acc_Mode,
	selected:   int, // note index in the active track, or -1
	drag:       Drag,
	undo:       [dynamic]Undo,
	redo:       [dynamic]Undo,

	player:     Player,
	follow:     bool,
	crush:      bool,

	// Panels
	overlay:      Overlay,
	open_files:   [dynamic]string,
	layer_scroll: int,
	editing_title: bool,
	title_buf:    [64]u8,
	title_len:    int,

	// A second click within a few seconds confirms something destructive.
	confirm_id:    [256]u8, // a copy, so it outlives whatever it named
	confirm_len:   int,
	confirm_until: f64,

	status:      [256]u8,
	status_len:  int,
	status_time: f64,
	status_bad:  bool,

	ui:     Ui_State,
	frames: u64,
	quit:   bool,
}

g: ^App

// The host calls, once: init_window then init. On a reload it calls neither -
// only app_hot_reloaded. On a restart (F6) it calls shutdown then init.
@(export)
game_init_window :: proc() {
	g = new(App)
	rlu.init(
		&g.v,
		APP_TITLE,
		rlu.Wanted{mode = .Windowed, w = 1920, h = 1080, at = {rlu.WINDOW_UNPLACED, rlu.WINDOW_UNPLACED}},
	)
	rl.SetTargetFPS(120)
	rl.InitAudioDevice()
}

@(export)
game_init :: proc() {
	g.follow = true
	g.crush = true
	g.length = .Quarter
	g.selected = -1
	g.fb_hand = HAND_DEFAULT
	files_init()
	music.mixer_init(&g.audio)
	instruments_reload(true)
	player_init(&g.player)
	if !open_last_song() {
		music.song_init(&g.song)
		music.song_add_track(&g.song, CELLO_KEY when CELLO else music.DEFAULT_KEY)
		when CELLO do cello_only()
	}
}

@(export)
game_update :: proc() -> bool {
	g.frames += 1
	rlu.update(&g.v)

	if rlu.too_small(&g.v) {
		rl.BeginDrawing()
		rl.ClearBackground(COL_BG)
		rl.DrawText("Make the window at least 1280 x 720.", 20, 20, 20, COL_TEXT)
		rl.EndDrawing()
		return !rl.WindowShouldClose()
	}

	if rl.IsKeyPressed(.F11) do rlu.toggle_fullscreen(&g.v)
	// F7, as in Animal Kingdoms: reload the data files - here, the instruments.
	if rl.IsKeyPressed(.F7) do instruments_reload(false)

	ui_begin()
	files_poll_dropped()
	g.audio.crush = g.crush
	player_update(&g.player, &g.song)
	if g.player.playing && g.follow {
		per_page := music.bar_ticks(&g.song) * BARS_PER_PAGE
		g.page = clamp(player_tick(&g.player, &g.song) / per_page, 0, page_count() - 1)
	}

	// Input, top-most first: an overlay swallows the mouse before the panels
	// see it, the panels before the sheet.
	keys_update()
	{
		rlu.begin(&g.v)
		rl.ClearBackground(COL_BG)
		// With an overlay up, nothing underneath it may take the mouse: the
		// frame's input is set aside, the page drawn deaf, and the input
		// handed to the overlay alone.
		//
		// `was_open` is decided BEFORE the panels run. A panel button that
		// opens an overlay (Add instrument, Open) does so with this frame's
		// click; if the check came after, that same click would be handed to
		// the brand-new overlay, land outside its box, and close it again -
		// the overlay would flash for one frame and vanish.
		was_open := !overlay_none()
		held := g.ui
		if was_open do ui_take_all()
		sheet_draw()
		panel_draw()
		topbar_draw()
		statusbar_draw()
		if was_open do g.ui = held
		overlay_draw()
		// The sheet reads the mouse last, after everything drawn over it
		// has had its chance to claim the click.
		sheet_input()
	}
	rlu.present(&g.v)

	free_all(context.temp_allocator)
	return !rl.WindowShouldClose() && !g.quit
}

@(export)
game_shutdown :: proc() {
	player_destroy(&g.player)
	music.song_destroy(&g.song)
	music.registry_bind(nil)
	music.mixer_destroy(&g.audio)
	undo_clear()
	delete(g.undo)
	delete(g.redo)
	files_destroy()
}

@(export)
game_shutdown_window :: proc() {
	rl.CloseAudioDevice()
	rlu.destroy(&g.v)
	rl.CloseWindow()
	free(g)
}

@(export)
game_memory :: proc() -> rawptr {
	return g
}

@(export)
game_memory_size :: proc() -> int {
	return size_of(App)
}

@(export)
game_hot_reloaded :: proc(mem: rawptr) {
	g = (^App)(mem)
	// The library's globals are fresh; point the music package back at the
	// registry, which lives here in the memory block.
	music.mixer_bind(&g.audio)
	set_status("code reloaded")
}

@(export)
game_force_reload :: proc() -> bool {
	return rl.IsKeyPressed(.F5)
}

@(export)
game_force_restart :: proc() -> bool {
	return rl.IsKeyPressed(.F6)
}

// ---------------------------------------------------------------------------

set_status :: proc(format: string, args: ..any) {
	s := fmt.bprintf(g.status[:], format, ..args)
	g.status_len = len(s)
	g.status_time = rl.GetTime()
	g.status_bad = false
}

set_error :: proc(format: string, args: ..any) {
	set_status(format, ..args)
	g.status_bad = true
}

status_text :: proc() -> string {
	return string(g.status[:g.status_len])
}

// Destructive actions (New, Open over unsaved work, Remove layer) ask by
// needing a second click on the same thing within three seconds.
confirmed :: proc(id: string, question: string) -> bool {
	now := rl.GetTime()
	if string(g.confirm_id[:g.confirm_len]) == id && now < g.confirm_until {
		g.confirm_len = 0
		return true
	}
	g.confirm_len = copy(g.confirm_id[:], id)
	g.confirm_until = now + 3
	set_error("%s - click again to confirm", question)
	return false
}
