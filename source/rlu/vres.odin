package rlu

/*
    Virtual resolution.

    The whole game draws into a small off-screen canvas which is then blown up
    to the window by a whole-number factor. Everything crisp about pixel art
    depends on that factor being an integer: at 2.5x, a one-pixel outline is
    two pixels on some rows and three on others, and the art shimmers when it
    moves.

    Two independent scales, easy to confuse:

      WINDOW SCALE   canvas -> window. Chosen automatically, and NOT an integer:
                     it is whatever fills one axis of the window exactly. On a
                     1920x1080 screen that happens to be a clean 2x; on a
                     2560x1440 one it is 2.667, and `blit` has a two-step
                     upscale that keeps that sharp. See `fit`.

      CAMERA ZOOM    world -> canvas. Chosen by the player, and an integer at
                     and above 1x (see ZOOM_LEVELS). Zooming in shows fewer,
                     bigger tiles; there is deliberately no zoom below 1x for
                     play, because scaling pixel art DOWN destroys it in a way
                     scaling up does not.

    Adapted from rlutil/vres in odins-raylib-examples, with the letterbox and
    virtual-mouse mapping kept and the rest trimmed.
*/

import "core:math"
import rl "vendor:raylib"

// 16:9, and the size the whole app is drawn at before it is blown up to the
// window.
//
// 1280 x 720 for the music box (Animal Kingdoms uses 960 x 540). It is the
// smallest size the sheet is laid out for - 52 staff rows of 12 pixels, four
// bars across - and it scales cleanly: 1:1 at 720p, exactly 2x at 1440p, and
// 1.5x at 1080p through the two-step sharp upscale in `blit`.
V_WIDTH :: 1280
V_HEIGHT :: 720

// World->canvas factors, smallest first.
//
// Everything at 1 and above is an integer factor, which is what keeps pixel art
// crisp; those are the levels a player cycles through. Below 1 are the
// zoom-outs, each a reciprocal power of two so a tile still lands on a whole
// number of pixels: at 1/16 a 16px tile is exactly one pixel, which is the
// point — it is how you see a whole world at once.
ZOOM_LEVELS :: [7]f32{1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1, 2, 3}

// Index of 1x. At and above it the art is crisp; below it you are looking at a
// map rather than at a world, which is right for the world generator and wrong
// for play, so the settings screen only offers these.
ZOOM_PLAY_FIRST :: 4

zoom_index_of :: proc(multiplier: f32) -> int {
	levels := ZOOM_LEVELS
	best, best_d := ZOOM_PLAY_FIRST, f32(1e30)
	for z, i in levels {
		d := abs(z - multiplier)
		if d < best_d {
			best_d = d
			best = i
		}
	}
	return best
}

// The blur runs at a fraction of the canvas, which is where the softness comes
// from: downsample, then draw back up through a bilinear filter. Six is enough
// that a 1280x720 canvas becomes 213x120 — recognisable as the map, unreadable as
// text, which is exactly what a menu wants behind it.
BLUR_DIV :: 6
BLUR_W :: V_WIDTH / BLUR_DIV
BLUR_H :: V_HEIGHT / BLUR_DIV

Virtual :: struct {
	canvas:      rl.RenderTexture2D,
	// Allocated on first use: a game that never opens a menu never pays for it.
	blur:        rl.RenderTexture2D,
	has_blur:    bool,
	// The canvas -> window factor. NOT an integer unless `integer_scale` is
	// set: see `update`.
	scale:       f32,
	// Refuse fractional scales and accept the bars instead. Off by default -
	// filling the screen is worth one softened boundary pixel per stroke to
	// most people - and on for the ones who would rather have an exact grid.
	// (SCALE-1 in Animal Kingdoms' .design/SCALING.md.)
	integer_scale: bool,
	// The whole-number step the canvas is enlarged by before it is fitted.
	// 1 when `scale` is already whole, in which case there is no middle step
	// at all and the canvas goes straight to the window.
	sharp_step:  i32,
	sharp:       rl.RenderTexture2D,
	has_sharp:   bool,
	dest:        rl.Rectangle, // destination in window space
	letterbox:   rl.Color,
	// The window is smaller than the canvas and the game cannot be drawn. See
	// `too_small`.
	unusable:    bool,
	initialised: bool,
}

// The smallest screen the game can be played on. The canvas is the game's
// layout - every screen is composed against it and nothing reflows - so a
// display that cannot show all of it cannot show the game.
MIN_SCREEN_W :: V_WIDTH
MIN_SCREEN_H :: V_HEIGHT

// The frame cap. raylib with VSYNC_HINT follows the monitor, which is a
// reasonable default and not a controllable one: it cannot be lowered, and on a
// 165Hz panel it means the game works four times as hard as it needs to.
// SetTargetFPS puts a ceiling under it that the player owns.
set_target_fps :: proc(fps: i32) {
	rl.SetTargetFPS(clamp(fps, 0, 1000)) // 0 means uncapped
}

// What the window should be when it opens. The player's last session, read out
// of settings.txt before the window exists - which is the only order that
// works, because a window opened at the wrong size and then corrected is a
// visible flash and a wrong first frame.
Wanted :: struct {
	mode:          Display_Mode,
	w, h:          i32,
	// Where the window was last time, or WINDOW_UNPLACED. Validated against
	// the monitors that exist now; see `window_spot`.
	at:            [2]i32,
	integer_scale: bool,
	// Did the size above come from the player, or is it our own first-run
	// guess? A size they chose is honoured up to the edge of the monitor; a
	// size we guessed is also kept clear of the desktop's furniture. Nobody
	// wants their deliberate 2560 x 1440 second-guessed, and nobody wants our
	// guess to open with its title bar under the taskbar.
	remembered:    bool,
}

init :: proc(v: ^Virtual, title: cstring, want := Wanted{mode = .Windowed, w = V_WIDTH * 2, h = V_HEIGHT * 2, at = {WINDOW_UNPLACED, WINDOW_UNPLACED}}) {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})

	// Opened at the wanted windowed size whatever the mode, because both of
	// raylib's mode toggles work off the window that already exists, and
	// because leaving Borderless later has to land on a real window size
	// rather than on the monitor.
	//
	// The monitor gets a veto on the size. Our own guess is kept to nine
	// tenths of the screen, because 1920 x 1080 windowed on a 1080p desktop is
	// a window with its title bar under the taskbar and the player's first act
	// is to fight it. A size the PLAYER chose is honoured right up to the edge
	// of the monitor instead - they can see their own taskbar.
	//
	// Either way the step-down goes to the largest size we offer that fits,
	// not to the canvas: somebody who asked for something big should get the
	// nearest big thing, not the smallest thing.
	//
	// The monitor is not knowable until the window exists, so this asks
	// afterwards and resizes if it has to.
	w := max(want.w, i32(V_WIDTH))
	h := max(want.h, i32(V_HEIGHT))
	rl.InitWindow(w, h, title)
	rl.SetWindowMinSize(V_WIDTH, V_HEIGHT)
	rl.SetExitKey(.KEY_NULL)

	if m := rl.GetCurrentMonitor(); true {
		mw, mh := rl.GetMonitorWidth(m), rl.GetMonitorHeight(m)
		room_w := want.remembered ? mw : mw * 9 / 10
		room_h := want.remembered ? mh : mh * 9 / 10
		if mw > 0 && mh > 0 && (w > room_w || h > room_h) {
			r := largest_fitting(room_w, room_h)
			w, h = r.w, r.h
		}
	}

	v.integer_scale = want.integer_scale
	v.canvas = rl.LoadRenderTexture(V_WIDTH, V_HEIGHT)
	rl.SetTextureFilter(v.canvas.texture, .POINT)
	v.letterbox = {12, 14, 11, 255}
	v.initialised = true

	// Placed before the mode is applied, so that Borderless and Fullscreen
	// land on the monitor the player was last on rather than on whichever one
	// the window manager happened to open us on. That is the whole of SCALE-2.
	set_mode(v, want.mode, w, h, want.at)
}

destroy :: proc(v: ^Virtual) {
	if !v.initialised do return
	rl.UnloadRenderTexture(v.canvas)
	if v.has_blur {
		rl.UnloadRenderTexture(v.blur)
		v.has_blur = false
	}
	if v.has_sharp {
		rl.UnloadRenderTexture(v.sharp)
		v.has_sharp = false
	}
	v.initialised = false
}

// Recompute the scale and the destination rectangle. Cheap; call every frame.
//
// FIT ONE AXIS, NOT BOTH. The scale used to be forced to a whole number, which
// is the sharpest thing to do and, on a screen whose size is not a multiple of
// the canvas, wastes a great deal of it: at 2560 x 1440 the largest whole-number
// step is 2, so the game drew at 1920 x 1080 with 320 pixels of black down each
// side AND 180 top and bottom. The canvas and every common screen are both 16:9,
// so a fractional factor fills the screen exactly with no bars at all; on an
// unusual aspect it fills one axis and leaves bars on the other, never both.
//
// The cost is that a fractional factor duplicates canvas pixels unevenly - at
// 2.667 they land in a 3, 3, 2 pattern - which is what `sharp_step` is for. See
// `blit`.
update :: proc(v: ^Virtual) {
	measured(v, f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()))
}

// `update` with the window size handed in.
//
// Split out for the third time in this file, and for the same reason: the
// interesting part is what gets WRITTEN ONTO the Virtual, and a procedure that
// asks raylib for the window cannot be checked without one. Everything that
// reads `scale`, `sharp_step`, `dest` or `unusable` is reading what this put
// there, including whether the integer-scale setting on the struct was
// consulted at all.
measured :: proc(v: ^Virtual, w, h: f32) {
	v.unusable = below_minimum(w, h)
	v.scale, v.sharp_step, v.dest = fit(w, h, v.integer_scale)
}

// Is a window of this size below the minimum the game will run at?
//
// Split out for the same reason `fit` is: it is the rule the game refuses to
// launch on, and a rule that important should be checked without needing a
// window. EITHER axis short is enough - the canvas does not reflow, so a
// 1920 x 400 letterbox is exactly as unplayable as a 400 x 400 one.
below_minimum :: proc(w, h: f32) -> bool {
	return w < MIN_SCREEN_W || h < MIN_SCREEN_H
}

// The arithmetic of `update`, with the window passed in.
//
// Split out so tools/uicheck can walk every resolution anyone is going to play
// on - and several nobody will - without opening a window. What is worth
// holding down here is not a picture: it is that the game fills at least one
// axis exactly, never overflows either, never leaves bars on both, and only
// pays for the two-step upscale when the scale is genuinely fractional.
// `integer_only` throws the fractional part away instead, which is the
// pixel-perfect answer and the wasteful one: 2560 x 1440 drops to x2 and draws
// 1920 x 1080 with bars all round. It is a setting rather than the default
// because most people would rather have the whole monitor. See SCALE-1.
fit :: proc(w, h: f32, integer_only := false) -> (scale: f32, step: i32, dest: rl.Rectangle) {
	scale = max(min(w / V_WIDTH, h / V_HEIGHT), 1)
	if integer_only do scale = math.floor(scale)

	// The whole-number step to enlarge by before fitting. A scale that is
	// already whole needs none, which is the common case - 1920 x 1080 and
	// 3840 x 2160 both land on it, and so does every scale when integer_only
	// is set - and the one that has to stay free.
	step = scale - math.floor(scale) < 0.001 ? 1 : i32(math.ceil(scale))

	dw := f32(V_WIDTH) * scale
	dh := f32(V_HEIGHT) * scale
	dest = {(w - dw) * 0.5, (h - dh) * 0.5, dw, dh}
	return
}

// Is the window too small to draw the game in?
//
// The canvas is the layout. Nothing on any screen reflows - the sheet, the
// layer list, every panel - so a window that cannot show
// 1280 x 720 cannot show the app, and pretending otherwise means clipping
// controls the player needs. game_update refuses to run on one, and says so on
// screen rather than exiting silently.
too_small :: proc(v: ^Virtual) -> bool {
	return v.unusable
}

// Blur what is already on the canvas, in place, and darken it.
//
// Two texture passes: the canvas down into a sixth-size buffer, then that
// buffer back up over the canvas through a bilinear filter. The canvas is
// POINT-filtered so the game stays crisp, so the downsample borrows BILINEAR
// for one draw and hands it straight back — without that the small buffer is a
// nearest-neighbour pick of every sixth pixel, which is not a blur, it is
// noise.
//
// Must be called OUTSIDE a begin/end pair: it reads the canvas and writes to
// it, and a render texture cannot be both at once.
blur_canvas :: proc(v: ^Virtual, scrim: u8 = 0) {
	if !v.initialised do return
	if !v.has_blur {
		v.blur = rl.LoadRenderTexture(BLUR_W, BLUR_H)
		rl.SetTextureFilter(v.blur.texture, .BILINEAR)
		v.has_blur = true
	}

	// Down. Render textures are stored bottom-up, hence the negative height.
	rl.SetTextureFilter(v.canvas.texture, .BILINEAR)
	rl.BeginTextureMode(v.blur)
	rl.DrawTexturePro(
		v.canvas.texture,
		{0, 0, f32(V_WIDTH), -f32(V_HEIGHT)},
		{0, 0, f32(BLUR_W), f32(BLUR_H)},
		{0, 0},
		0,
		rl.WHITE,
	)
	rl.EndTextureMode()
	rl.SetTextureFilter(v.canvas.texture, .POINT)

	// Up, over the canvas, plus the scrim in one pass.
	rl.BeginTextureMode(v.canvas)
	rl.DrawTexturePro(
		v.blur.texture,
		{0, 0, f32(BLUR_W), -f32(BLUR_H)},
		{0, 0, f32(V_WIDTH), f32(V_HEIGHT)},
		{0, 0},
		0,
		rl.WHITE,
	)
	if scrim > 0 do rl.DrawRectangle(0, 0, V_WIDTH, V_HEIGHT, {0, 0, 0, scrim})
	rl.EndTextureMode()
}

@(deferred_in = end)
begin :: proc(v: ^Virtual) {
	rl.BeginTextureMode(v.canvas)
}

end :: proc(v: ^Virtual) {
	rl.EndTextureMode()
}

// Blit the canvas to the window. The source height is negative because render
// textures are stored bottom-up.
// Blit the canvas to the window, integer-scaled and letterboxed.
//
// Split from `finish` so that native-resolution overlays — anything that must
// NOT be upscaled, such as a microui panel — have somewhere to go. Draw them
// between the two calls. Drawing after `finish` silently produces nothing,
// because EndDrawing has already submitted the frame.
blit :: proc(v: ^Virtual) {
	// A whole-number scale: straight to the window, nearest-neighbour, exact.
	// This is the fast path and the pretty one, and it is what a full-screen
	// 1920 x 1080 gets.
	if v.sharp_step <= 1 {
		rl.BeginDrawing()
		rl.ClearBackground(v.letterbox)
		src := rl.Rectangle{0, 0, f32(V_WIDTH), -f32(V_HEIGHT)}
		rl.DrawTexturePro(v.canvas.texture, src, v.dest, {0, 0}, 0, rl.WHITE)
		return
	}

	// A fractional scale, in two steps.
	//
	// Drawing the canvas straight to a fractional destination with POINT gives
	// uneven pixels - at 2.667 a one-pixel line is two screen pixels wide here
	// and three there, and a slow pan makes the whole screen crawl. Drawing it
	// with BILINEAR instead gives even pixels and a soft, smeared image.
	//
	// So: enlarge by a WHOLE number first, nearest-neighbour, which duplicates
	// every pixel exactly the same number of times; then shrink that to the
	// window with BILINEAR, which is now only ever removing a little rather
	// than inventing. Edges stay hard, the spacing stays even, and the cost is
	// one more texture and one more draw.
	step := v.sharp_step
	sw, sh := i32(V_WIDTH) * step, i32(V_HEIGHT) * step
	if !v.has_sharp || v.sharp.texture.width != sw || v.sharp.texture.height != sh {
		if v.has_sharp do rl.UnloadRenderTexture(v.sharp)
		v.sharp = rl.LoadRenderTexture(sw, sh)
		rl.SetTextureFilter(v.sharp.texture, .BILINEAR)
		v.has_sharp = true
	}

	rl.BeginTextureMode(v.sharp)
	rl.DrawTexturePro(
		v.canvas.texture,
		{0, 0, f32(V_WIDTH), -f32(V_HEIGHT)},
		{0, 0, f32(sw), f32(sh)},
		{0, 0},
		0,
		rl.WHITE,
	)
	rl.EndTextureMode()

	rl.BeginDrawing()
	rl.ClearBackground(v.letterbox)
	rl.DrawTexturePro(v.sharp.texture, {0, 0, f32(sw), -f32(sh)}, v.dest, {0, 0}, 0, rl.WHITE)
}

finish :: proc(v: ^Virtual) {
	rl.EndDrawing()
}

// Blit and finish in one call, for frames with no overlay.
present :: proc(v: ^Virtual) {
	blit(v)
	finish(v)
}

// Mouse position in canvas pixels. Everything in the game should use this and
// never rl.GetMousePosition directly.
mouse :: proc(v: ^Virtual) -> rl.Vector2 {
	m := rl.GetMousePosition()
	return {(m.x - v.dest.x) / v.scale, (m.y - v.dest.y) / v.scale}
}

mouse_in_canvas :: proc(v: ^Virtual) -> bool {
	m := mouse(v)
	return m.x >= 0 && m.y >= 0 && m.x < V_WIDTH && m.y < V_HEIGHT
}

// The window modes, the resolution list and the moving between them live in
// display.odin. This file is only about getting the canvas onto whatever
// rectangle they end up producing.
