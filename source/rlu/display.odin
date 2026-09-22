package rlu

/*
    Display modes, and the resolutions we offer.

    WHAT THIS FILE IS NOT. It is not where the canvas is scaled to the window -
    that is `fit` in vres.odin, and it happens whatever mode the window is in.
    The two are deliberately separate: the mode and the resolution decide how
    big a rectangle the game gets, and `fit` decides what to do with it. Nothing
    here has to know about pixels, and nothing there has to know about windows.

    THE RESOLUTION IS A WINDOWED SETTING. In Borderless and Fullscreen the
    window is the monitor, so the list is offered but does not apply, and the
    settings screen dims it. Saying "1280 x 720" while running full screen on a
    1440p panel would be a lie about something the player can see.

    EVERY LISTED RESOLUTION IS AT OR ABOVE THE MINIMUM. A resolution the game
    would then refuse to launch on is not a choice, it is a trap, so the list is
    checked against MIN_SCREEN_W/H rather than trusted. See tools/uicheck.
*/

import rl "vendor:raylib"

// How the window sits on the desktop.
//
// Borderless is the one most people actually want: the window is the monitor
// with no decoration, so alt-tab is instant and there is no video mode change
// to stutter through. Fullscreen is kept for the people who want the real
// thing. Both of them take the monitor's size, which is why the resolution
// below only applies to Windowed.
Display_Mode :: enum {
	Windowed,
	Borderless,
	Fullscreen,
}

// The names used in settings.txt. Stored as words rather than as a number,
// because `display_mode = borderless` survives a reorder of the enum and
// `display_mode = 1` does not.
DISPLAY_MODE_ID := [Display_Mode]string {
	.Windowed   = "windowed",
	.Borderless = "borderless",
	.Fullscreen = "fullscreen",
}

display_mode_from_string :: proc(s: string) -> (Display_Mode, bool) {
	for name, m in DISPLAY_MODE_ID do if name == s do return m, true
	return .Windowed, false
}

Resolution :: struct {
	w, h: i32,
	// What the player will recognise it as. Empty for the ones that need no
	// explaining; the label is the reason a 1280 x 800 entry is obviously the
	// Steam Deck rather than an odd laptop.
	note: string,
}

// The windowed sizes offered, smallest first.
//
// Chosen to cover what people actually run rather than to be exhaustive: the
// common 16:9 steps, the 16:10 sizes that laptops and the handhelds use, two
// ultrawides, and 4K. 1280 x 720 is the canvas itself, which is both the
// minimum and a genuinely useful size for a small window on a second monitor.
//
// SORTED BY AREA, smallest first, and checked to be so - the stepper walks this
// in order and a list that jumps around reads as a bug.
RESOLUTIONS := [?]Resolution {
	{1280, 720, "the canvas, 1:1"},
	{1280, 800, "Steam Deck"},
	{1366, 768, "common laptop"},
	{1440, 900, ""},
	{1600, 900, ""},
	{1680, 1050, ""},
	{1920, 1080, ""},
	{1920, 1200, ""},
	{2560, 1080, "ultrawide"},
	{2560, 1440, ""},
	{2560, 1600, ""},
	{3440, 1440, "ultrawide"},
	{3840, 2160, "4K"},
}

// The resolutions that fit on a monitor this size, written into `out`.
//
// Pure, so tools/uicheck can walk it across every monitor anyone might have
// without opening a window. Filtered rather than greyed out: an entry the
// window manager will immediately shrink is not a choice.
//
// NEVER EMPTY. A monitor smaller than the smallest entry gets that entry
// anyway - the game will refuse to launch on it and say why, which is a better
// answer than a stepper with nothing in it.
resolutions_for :: proc(mw, mh: i32, out: []Resolution) -> int {
	n := 0
	for r in RESOLUTIONS {
		if r.w > mw || r.h > mh do continue
		if n >= len(out) do break
		out[n] = r
		n += 1
	}
	if n == 0 && len(out) > 0 {
		out[0] = RESOLUTIONS[0]
		n = 1
	}
	return n
}

// The largest resolution we offer that fits inside w x h.
//
// The floor is the smallest entry - the canvas - even when that does not fit,
// because a window smaller than the canvas is refused at launch with a screen
// that says why, and that is a better answer than a window of no size at all.
largest_fitting :: proc(w, h: i32) -> Resolution {
	best := RESOLUTIONS[0]
	for r in RESOLUTIONS do if r.w <= w && r.h <= h do best = r
	return best
}

// The index in `list` of the resolution nearest to w x h.
//
// Nearest rather than exact: the player's saved size may have come from a
// bigger monitor, or from a hand-edited settings.txt, and landing on the
// closest thing that fits beats resetting them to the top of the list.
resolution_index :: proc(list: []Resolution, w, h: i32) -> int {
	best, best_d := 0, max(int)
	for r, i in list {
		d := abs(int(r.w) - int(w)) + abs(int(r.h) - int(h))
		if d < best_d {
			best_d = d
			best = i
		}
	}
	return best
}

// ---------------------------------------------------------------------------
// Which monitor, and where on it
// ---------------------------------------------------------------------------

// A monitor as a rectangle in desktop space.
//
// Desktop space has an origin at the primary monitor's top-left, so a screen
// to the LEFT of the primary has a negative x. That is why a window position
// cannot be validated by "is it positive" and has to be checked against the
// monitors that actually exist.
Monitor :: struct {
	x, y, w, h: i32,
}

// No remembered position. Written into settings.txt as -1 -1, which is not a
// position any window manager produces on purpose and is centred if it ever is.
WINDOW_UNPLACED :: i32(-1)

// The monitors attached right now.
monitors_now :: proc(out: []Monitor) -> int {
	n := 0
	for i in 0 ..< int(rl.GetMonitorCount()) {
		if n >= len(out) do break
		p := rl.GetMonitorPosition(i32(i))
		out[n] = {i32(p.x), i32(p.y), rl.GetMonitorWidth(i32(i)), rl.GetMonitorHeight(i32(i))}
		n += 1
	}
	return n
}

// Where to put a w x h window, given where it was last time.
//
// Pure, and the reason it is pure is that the interesting cases are all about
// hardware that is not here any more: the player unplugged the second monitor,
// or swapped a 4K for a 1080p, or took the laptop off the dock. A saved
// position then points at a screen that does not exist, and a window placed
// there is a window they cannot reach. So:
//
//   - the saved spot is used only if the window's CENTRE lands on a monitor
//     that exists now, which survives a window hanging slightly off an edge;
//   - the window is then nudged fully onto that monitor, because "mostly on
//     screen" still loses the title bar;
//   - otherwise it is centred on the first monitor, which raylib reports as
//     the primary.
//
// Returns WINDOW_UNPLACED unchanged when there are no monitors at all: there is
// nothing to validate against and guessing would be worse than letting the
// window manager decide.
window_spot :: proc(saved: [2]i32, w, h: i32, monitors: []Monitor) -> [2]i32 {
	if len(monitors) == 0 do return saved
	primary := monitors[0]
	// Clamped to the monitor's own corner: a window LARGER than the screen -
	// a size carried over from a bigger monitor - centres to a negative
	// position, and the part that goes off the top is the title bar the
	// player drags. Better to lose the bottom right, which they can still
	// reach the window without.
	centred := [2]i32 {
		max(primary.x, primary.x + (primary.w - w) / 2),
		max(primary.y, primary.y + (primary.h - h) / 2),
	}
	if saved.x == WINDOW_UNPLACED && saved.y == WINDOW_UNPLACED do return centred

	cx, cy := saved.x + w / 2, saved.y + h / 2
	for m in monitors {
		if cx < m.x || cx >= m.x + m.w do continue
		if cy < m.y || cy >= m.y + m.h do continue
		// On this one. Pull it fully inside, but never past the top-left -
		// a window taller than the monitor should lose its bottom, not its
		// title bar.
		return {
			max(m.x, min(saved.x, m.x + m.w - w)),
			max(m.y, min(saved.y, m.y + m.h - h)),
		}
	}
	return centred
}

// ---------------------------------------------------------------------------
// Moving the window between modes
// ---------------------------------------------------------------------------

// What mode the window is in right now, read from raylib rather than
// remembered. A remembered mode and a real one drift the first time something
// else changes the window - the player dragging it out of full screen, a
// window manager with opinions - and then the settings screen is lying.
current_mode :: proc() -> Display_Mode {
	if rl.IsWindowFullscreen() do return .Fullscreen
	if rl.IsWindowState({.BORDERLESS_WINDOWED_MODE}) do return .Borderless
	return .Windowed
}

is_fullscreen :: proc() -> bool {
	return current_mode() != .Windowed
}

// Put the window into `mode` at `w` x `h`, and recompute the scale.
//
// The size is only used by Windowed. Going TO windowed always sets a size,
// because raylib leaves the window at whatever the monitor was and a window the
// size of the desktop is not a window anyone wanted.
set_mode :: proc(v: ^Virtual, mode: Display_Mode, w, h: i32, at := [2]i32{WINDOW_UNPLACED, WINDOW_UNPLACED}) {
	now := current_mode()

	// Leave whatever we are in first. Both of raylib's toggles are toggles
	// rather than setters, and going straight from one to the other leaves the
	// window in a state neither of them expects.
	if now == .Fullscreen do rl.ToggleFullscreen()
	else if now == .Borderless do rl.ToggleBorderlessWindowed()

	switch mode {
	case .Windowed:
		set_window_size(w, h, at)
	case .Borderless:
		rl.ToggleBorderlessWindowed()
		// And make sure it really did take the monitor.
		//
		// raylib's toggle sizes the window itself, and on a normal desktop
		// that is the end of it. Without a window manager - a bare X server,
		// which is what the screenshot harness runs under - the resize does
		// not stick, and the game then draws borderless at whatever size the
		// window happened to be. Correcting it here costs one comparison and
		// removes a whole class of "it works on my machine".
		m := rl.GetCurrentMonitor()
		mw, mh := rl.GetMonitorWidth(m), rl.GetMonitorHeight(m)
		if mw > 0 && mh > 0 && (rl.GetScreenWidth() != mw || rl.GetScreenHeight() != mh) {
			rl.SetWindowSize(mw, mh)
			p := rl.GetMonitorPosition(m)
			rl.SetWindowPosition(i32(p.x), i32(p.y))
		}
	case .Fullscreen:
		m := rl.GetCurrentMonitor()
		rl.SetWindowSize(rl.GetMonitorWidth(m), rl.GetMonitorHeight(m))
		rl.ToggleFullscreen()
	}
	update(v)
}

// Resize the windowed window and put it somewhere sensible.
//
// `at` is where it was last time, or WINDOW_UNPLACED to centre it. Either way
// the position goes through `window_spot`, so a remembered spot on a monitor
// that has since been unplugged does not strand the window off screen.
set_window_size :: proc(w, h: i32, at := [2]i32{WINDOW_UNPLACED, WINDOW_UNPLACED}) {
	rl.SetWindowSize(w, h)
	mons: [MAX_MONITORS]Monitor
	n := monitors_now(mons[:])
	p := window_spot(at, w, h, mons[:n])
	if n > 0 do rl.SetWindowPosition(p.x, p.y)
}

// More than anyone has, and a bound so nothing here allocates.
MAX_MONITORS :: 16

// Where the window is now, for saving. WINDOW_UNPLACED in any mode but
// Windowed: the position of a borderless window is the monitor's corner, and
// writing that down would make "remember where I was" mean "remember which
// corner", which is not the same thing.
window_spot_now :: proc() -> [2]i32 {
	if current_mode() != .Windowed do return {WINDOW_UNPLACED, WINDOW_UNPLACED}
	p := rl.GetWindowPosition()
	return {i32(p.x), i32(p.y)}
}

// F11: windowed <-> borderless, and out of fullscreen into windowed.
//
// Borderless rather than fullscreen, because F11 means "make it big" and
// borderless is the cheaper, friendlier way to be big. The mode toggle in
// Settings is where the real fullscreen lives.
toggle_fullscreen :: proc(
	v: ^Virtual,
	windowed_w := i32(V_WIDTH * 2),
	windowed_h := i32(V_HEIGHT * 2),
	at := [2]i32{WINDOW_UNPLACED, WINDOW_UNPLACED},
) {
	set_mode(v, current_mode() == .Windowed ? .Borderless : .Windowed, windowed_w, windowed_h, at)
}
