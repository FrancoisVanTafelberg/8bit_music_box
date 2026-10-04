package app

/*
    The window, and how big the UI is in it.

    NO CANVAS. The app used to draw into a fixed 1280 x 720 picture and blow
    it up to the window (rlu, from Animal Kingdoms: right for a pixel-art
    game, wrong for a tool - text, staff lines and note heads all came out
    as big soft pixels). Now everything is drawn straight to the window at
    its real resolution, the way the fuzzyfinder does it, so it is sharp at
    any size.

    The layout is still written in one unit - call it a point - and the UI
    SCALE says how many pixels a point is (g.scale; ui_scale_update, every
    frame). Drawing goes through a 2D camera zoomed by it, so a line, a box
    or a note head is laid out in points and drawn in pixels. Text is the
    exception that makes it work: the font is rasterised at the PIXEL size
    (FONT x scale) and drawn at the point size, so each glyph lands on the
    screen one texel to one pixel (ui.odin).

    The layout reads the window's size every frame - screen_w(), screen_h(),
    in points - so a bigger window gives the sheet more room: wider bars,
    taller rows, a longer fingerboard. Nothing assumes 1280 x 720 any more;
    that is only the least room the layout needs.

    The scale: by default the largest (in 5% steps) that still leaves the
    layout its 1280 x 720 points - 1 on a 720p window, 1.5 at 1080p, 2 at
    1440p, 3 at 4K, and whatever fits in between for a window of any other
    size. Ctrl+- makes everything 10% smaller (more room for the music),
    Ctrl+= bigger again, Ctrl+0 back to automatic. Remembered in
    settings.txt.
*/

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

LAYOUT_W :: 1280 // the least room, in points, the layout is made for
LAYOUT_H :: 720
SCALE_MIN :: f32(0.75)
SCALE_MAX :: f32(4)
SETTINGS_FILE :: "settings.txt"

// The window's size in points.
screen_w :: proc() -> f32 {return f32(rl.GetScreenWidth()) / g.scale}
screen_h :: proc() -> f32 {return f32(rl.GetScreenHeight()) / g.scale}

// Open the window: 1920 x 1080, or nine tenths of a smaller monitor.
window_open :: proc(title: cstring) {
	rl.SetTraceLogLevel(.WARNING)
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT, .MSAA_4X_HINT})
	// MUSIC_BOX_WINDOW=2560x1440 opens at another size: for trying the
	// layout out (and the screenshot tests) at sizes this screen is not.
	ww, wh := i32(1920), i32(1080)
	forced := false
	if env := os.get_env("MUSIC_BOX_WINDOW", context.temp_allocator); env != "" {
		if parts := strings.split(env, "x", context.temp_allocator); len(parts) == 2 {
			pw, ok1 := strconv.parse_int(parts[0])
			ph, ok2 := strconv.parse_int(parts[1])
			if ok1 && ok2 {ww, wh = i32(pw), i32(ph); forced = true}
		}
	}
	rl.InitWindow(ww, wh, title)
	rl.SetExitKey(.KEY_NULL)
	rl.SetWindowMinSize(i32(LAYOUT_W * SCALE_MIN), i32(LAYOUT_H * SCALE_MIN))
	m := rl.GetCurrentMonitor()
	mw, mh := rl.GetMonitorWidth(m), rl.GetMonitorHeight(m)
	if !forced && mw > 0 && mh > 0 && (mw * 9 / 10 < ww || mh * 9 / 10 < wh) {
		w := max(min(1920, mw * 9 / 10), i32(LAYOUT_W * SCALE_MIN))
		h := max(min(1080, mh * 9 / 10), i32(LAYOUT_H * SCALE_MIN))
		rl.SetWindowSize(w, h)
		p := rl.GetMonitorPosition(m)
		rl.SetWindowPosition(i32(p.x) + (mw - w) / 2, i32(p.y) + (mh - h) / 2)
	}
	ui_scale_update()
}

// F11: borderless full screen and back (the windowed size is kept).
fullscreen_toggle :: proc() {
	rl.ToggleBorderlessWindowed()
}

// The largest scale (in steps of 5%) that leaves the layout its room.
ui_scale_fit :: proc() -> f32 {
	w, h := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	fit := min(w / LAYOUT_W, h / LAYOUT_H)
	return clamp(math.floor(fit * 20 + 0.001) / 20, SCALE_MIN, SCALE_MAX)
}

// Every frame, before anything is laid out: the scale for this window, and
// the fonts rasterised for it if it has changed.
ui_scale_update :: proc() {
	fit := ui_scale_fit()
	s := fit
	if g.ui_size > 0 do s = clamp(g.ui_size, SCALE_MIN, fit)
	g.scale = s
	if !g.fonts.loaded || g.fonts.scale != s do fonts_load(&g.fonts, s)
}

// Ctrl+= (+1), Ctrl+- (-1), Ctrl+0 (0: automatic).
ui_size_step :: proc(dir: int) {
	fit := ui_scale_fit()
	if dir == 0 {
		g.ui_size = 0
	} else {
		cur := g.ui_size > 0 ? g.ui_size : fit
		next := clamp(math.round((cur + f32(dir) * 0.1) * 20) / 20, SCALE_MIN, fit)
		// Back at the largest that fits: that is automatic.
		g.ui_size = next >= fit ? 0 : next
	}
	ui_scale_update()
	settings_save()
	auto := g.ui_size == 0
	set_status("UI size %d%%%s  (Ctrl+- smaller, Ctrl+= bigger, Ctrl+0 automatic)", int(g.scale * 100 + 0.5), auto ? " - automatic, the largest this window fits" : "")
}

// settings.txt: one setting a line, `name value`. Only the UI size for now.
settings_load :: proc() {
	data, err := os.read_entire_file_from_path(join(SETTINGS_FILE), context.temp_allocator)
	if err != nil do return
	for line in strings.split_lines(string(data), context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) < 2 do continue
		switch f[0] {
		case "ui_size":
			if f[1] == "auto" do g.ui_size = 0
			else if v, ok := strconv.parse_f32(f[1]); ok do g.ui_size = clamp(v, SCALE_MIN, SCALE_MAX)
		}
	}
}

settings_save :: proc() {
	s := g.ui_size > 0 ? fmt.tprintf("ui_size %.2f\n", g.ui_size) : "ui_size auto\n"
	_ = os.write_entire_file(join(SETTINGS_FILE), transmute([]u8)s)
}

// ---------------------------------------------------------------------------
// The font
// ---------------------------------------------------------------------------

// JetBrains Mono (SIL Open Font License: source/fonts/OFL.txt), inside the
// exe, so it needs no files beside it and looks the same everywhere. The
// same face the fuzzyfinder uses.
@(rodata)
FONT_TTF := #load("fonts/JetBrainsMono-Regular.ttf")

Fonts :: struct {
	small:  rl.Font, // FONT points
	big:    rl.Font, // FONT_BIG points
	scale:  f32, // the UI scale they were rasterised for
	loaded: bool,
}

@(private = "file")
font_codepoints :: proc() -> []rune {
	out := make([dynamic]rune, 0, 512, context.temp_allocator)
	ranges := [?][2]rune {
		{0x20, 0x7E}, // ASCII first: raylib finds a glyph by a linear scan
		{0xA0, 0x17F}, // Latin-1, Latin Extended-A
		{0x2010, 0x2027}, // dashes, quotes, bullet, ellipsis
		{0x2190, 0x21FF}, // arrows
		{0x2200, 0x22FF}, // maths
		{0x2500, 0x259F}, // box drawing, blocks
		{0x25A0, 0x25FF}, // shapes
	}
	for r in ranges do for c := r[0]; c <= r[1]; c += 1 do append(&out, c)
	return out[:]
}

fonts_load :: proc(f: ^Fonts, scale: f32) {
	fonts_unload(f)
	cps := font_codepoints()
	load :: proc(points: i32, scale: f32, cps: []rune) -> rl.Font {
		px := i32(math.round(f32(points) * scale))
		font := rl.LoadFontFromMemory(".ttf", raw_data(FONT_TTF), i32(len(FONT_TTF)), px, raw_data(cps), i32(len(cps)))
		rl.SetTextureFilter(font.texture, .BILINEAR)
		return font
	}
	f.small = load(FONT, scale, cps)
	f.big = load(FONT_BIG, scale, cps)
	f.scale = scale
	f.loaded = true
}

fonts_unload :: proc(f: ^Fonts) {
	if !f.loaded do return
	rl.UnloadFont(f.small)
	rl.UnloadFont(f.big)
	f.loaded = false
}
