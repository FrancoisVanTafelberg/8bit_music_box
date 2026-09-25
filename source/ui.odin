package app

/*
    Widgets, hand-rolled, in the app's palette.

    Immediate mode, and deliberately tiny: a button is a rectangle that returns
    true on the frame it was clicked. Everything is drawn into the 1280 x 720
    canvas with raylib's default font, which is a pixel font - at 2x on a 1440p
    screen it is exactly the 8-bit look we want.

    One rule: the first widget to see a click CONSUMES it (ui_take_click), so a
    button drawn over the sheet does not also drop a note underneath it.
    Overlays are drawn after the panels but checked first, via `overlay_blocks`.
*/

import "core:strings"
import "rlu"
import rl "vendor:raylib"

// --- Palette: a dark NES-ish night sky ---
COL_BG :: rl.Color{14, 16, 28, 255}
COL_PANEL :: rl.Color{24, 26, 44, 255}
COL_PANEL_HI :: rl.Color{38, 41, 68, 255}
COL_SHEET :: rl.Color{18, 20, 34, 255}
COL_EDGE :: rl.Color{58, 62, 98, 255}
COL_TEXT :: rl.Color{226, 226, 240, 255}
COL_DIM :: rl.Color{128, 132, 164, 255}
COL_FAINT :: rl.Color{80, 84, 116, 255}
COL_ACCENT :: rl.Color{255, 204, 64, 255}
COL_GOOD :: rl.Color{110, 220, 140, 255}
COL_BAD :: rl.Color{250, 96, 96, 255}
COL_BUTTON :: rl.Color{44, 48, 80, 255}
COL_BUTTON_HOT :: rl.Color{64, 70, 116, 255}
COL_BUTTON_ON :: rl.Color{92, 78, 34, 255}

FONT :: 10 // the default font's own size: crisp
FONT_BIG :: 20 // exactly 2x: still crisp

Ui_State :: struct {
	mouse:   rl.Vector2,
	clicked: bool, // left button went down this frame and nobody has taken it
	right:   bool,
	wheel:   f32,
	down:    bool,
}

ui_begin :: proc() {
	g.ui.mouse = rlu.mouse(&g.v)
	g.ui.clicked = rl.IsMouseButtonPressed(.LEFT)
	g.ui.right = rl.IsMouseButtonPressed(.RIGHT)
	g.ui.wheel = rl.GetMouseWheelMove()
	g.ui.down = rl.IsMouseButtonDown(.LEFT)
}

hovered :: proc(r: rl.Rectangle) -> bool {
	return rl.CheckCollisionPointRec(g.ui.mouse, r)
}

// Claim this frame's click if it landed in `r`.
ui_take_click :: proc(r: rl.Rectangle) -> bool {
	if g.ui.clicked && hovered(r) {
		g.ui.clicked = false
		return true
	}
	return false
}

ui_take_right :: proc(r: rl.Rectangle) -> bool {
	if g.ui.right && hovered(r) {
		g.ui.right = false
		return true
	}
	return false
}

ui_take_wheel :: proc(r: rl.Rectangle) -> f32 {
	if g.ui.wheel != 0 && hovered(r) {
		w := g.ui.wheel
		g.ui.wheel = 0
		return w
	}
	return 0
}

// Swallow everything (a modal overlay is up and the click missed it).
ui_take_all :: proc() {
	g.ui.clicked = false
	g.ui.right = false
	g.ui.wheel = 0
}

rect :: proc(x, y, w, h: f32) -> rl.Rectangle {
	return {x, y, w, h}
}

fill :: proc(r: rl.Rectangle, c: rl.Color) {
	rl.DrawRectangle(i32(r.x), i32(r.y), i32(r.width), i32(r.height), c)
}

outline :: proc(r: rl.Rectangle, c: rl.Color) {
	rl.DrawRectangleLines(i32(r.x), i32(r.y), i32(r.width), i32(r.height), c)
}

text :: proc(s: string, x, y: f32, c: rl.Color = COL_TEXT, size: i32 = FONT) {
	rl.DrawText(strings.clone_to_cstring(s, context.temp_allocator), i32(x), i32(y), size, c)
}

text_width :: proc(s: string, size: i32 = FONT) -> f32 {
	return f32(rl.MeasureText(strings.clone_to_cstring(s, context.temp_allocator), size))
}

text_centered :: proc(s: string, r: rl.Rectangle, c: rl.Color = COL_TEXT, size: i32 = FONT) {
	w := text_width(s, size)
	text(s, r.x + (r.width - w) / 2, r.y + (r.height - f32(size)) / 2, c, size)
}

// Cut a label down to fit, with a trailing '..'.
fit_text :: proc(s: string, width: f32) -> string {
	if text_width(s) <= width do return s
	n := len(s)
	for n > 0 && text_width(strings.concatenate({s[:n], ".."}, context.temp_allocator)) > width do n -= 1
	return strings.concatenate({s[:n], ".."}, context.temp_allocator)
}

button :: proc(r: rl.Rectangle, label: string, on := false, enabled := true) -> bool {
	hot := enabled && hovered(r)
	bg := on ? COL_BUTTON_ON : (hot ? COL_BUTTON_HOT : COL_BUTTON)
	if !enabled do bg = COL_PANEL
	fill(r, bg)
	outline(r, on ? COL_ACCENT : COL_EDGE)
	text_centered(fit_text(label, r.width - 4), r, enabled ? (on ? COL_ACCENT : COL_TEXT) : COL_FAINT)
	return enabled && ui_take_click(r)
}

label :: proc(s: string, x, y: f32) {
	text(s, x, y, COL_DIM)
}

with_alpha :: proc(c: rl.Color, a: u8) -> rl.Color {
	return {c.r, c.g, c.b, a}
}

lighten :: proc(c: rl.Color, t: f32) -> rl.Color {
	l :: proc(v: u8, t: f32) -> u8 {return u8(f32(v) + (255 - f32(v)) * t)}
	return {l(c.r, t), l(c.g, t), l(c.b, t), c.a}
}

inst_color :: proc(c: [4]u8) -> rl.Color {
	return {c[0], c[1], c[2], c[3]}
}

// A number with - and + either side. A click moves it by `unit`; with Shift
// held, 10 units; with Ctrl, 100 (as Animal Kingdoms' count boxes do). The
// mouse wheel over it does the same, and a right-click puts it back to
// `reset`. `shown` formats the value for the middle.
stepper :: proc(r: rl.Rectangle, value, lo, hi, unit, reset: f32, shown: string) -> f32 {
	v := value
	step := unit
	if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) do step = unit * 10
	if rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) do step = unit * 100
	bw := f32(18)
	if button(rect(r.x, r.y, bw, r.height), "-") do v -= step
	mid := rect(r.x + bw, r.y, r.width - 2 * bw, r.height)
	fill(mid, hovered(mid) ? COL_BUTTON : COL_SHEET)
	text_centered(shown, mid)
	if button(rect(r.x + r.width - bw, r.y, bw, r.height), "+") do v += step
	whole := r
	if w := ui_take_wheel(whole); w != 0 do v += w > 0 ? step : -step
	if ui_take_right(mid) do v = reset
	// Keep whole units whole (0.1 + 0.2 is not quite 0.3).
	v = f32(int(v / unit + (v >= 0 ? 0.5 : -0.5))) * unit
	return clamp(v, lo, hi)
}
