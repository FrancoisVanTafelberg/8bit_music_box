package app

/*
    The Helper: a practice view for string players, switched on and off with
    the Helper button in the top bar (or H).

    With it on, the layer panel narrows, the sheet shows the selected layer's
    instrument's rows (the "inst" range), and the right of the screen shows
    that instrument's fingerboard (fingerboard.odin): every place each note is
    played, the hand positions, the path the hand takes (fingering.odin), and
    - in input mode - where the note you are playing is. Select another layer
    and the board changes with it.

    Which instruments have a board is up to their instrument files (a `board`
    line and its hand positions, music/board.odin): as shipped, the violin,
    viola, cello, contrabass and guitar. For the rest the panel says the
    Helper has nothing for them yet.

    (This used to be a separate program, the Cello Helper. It is the same
    thing, for every string instrument, inside the music box.)
*/

import "core:fmt"
import "core:strings"
import "music"
import rl "vendor:raylib"

helper_toggle :: proc() {
	g.helper = !g.helper
	if g.helper {
		// The instrument's rows are what a player reads; put the piano back
		// (if it was on) when the Helper goes.
		g.helper_fit = g.fit_range
		g.fit_range = true
		g.fb_inst_ok = false
		set_status("Helper on: the selected layer's fingerboard on the right - pick a string layer")
	} else {
		g.fit_range = g.helper_fit
		set_status("Helper off")
	}
}

// The right-hand panel, with the Helper on.
helper_draw :: proc() {
	fill(rect(FB_X, TOP_H, FB_W, 720 - TOP_H - STATUS_H), COL_PANEL)
	rl.DrawLine(FB_X, TOP_H, FB_X, 720 - STATUS_H, COL_EDGE)
	if fb_board() != nil {
		fingerboard_draw()
		return
	}
	x0 := f32(FB_X + 8)
	t := active_track()
	title := "HELPER"
	if t != nil do title = fmt.tprintf("%s HELPER", strings.to_upper(inst_of(t).name, context.temp_allocator))
	label(title, x0, TOP_H + 6)

	box := rect(FB_X + 20, TOP_H + 200, FB_W - 40, 170)
	fill(box, COL_SHEET)
	outline(box, COL_EDGE)
	y := box.y + 16
	text_centered("Fingerboard", rect(box.x, y, box.width, 20), COL_DIM, FONT_BIG)
	y += 26
	text_centered("not implemented", rect(box.x, y, box.width, 20), COL_ACCENT, FONT_BIG)
	y += 34
	if t != nil {
		text_centered(fmt.tprintf("for the %s yet", inst_of(t).name), rect(box.x, y, box.width, 12), COL_TEXT)
	} else {
		text_centered("select a layer", rect(box.x, y, box.width, 12), COL_TEXT)
	}
	y += 24
	// Which instruments do have one: whatever the instrument files say,
	// wrapped to the box.
	text_centered("Boards for:", rect(box.x, y, box.width, 12), COL_DIM)
	y += 14
	line := ""
	for &ins in music.reg().list {
		if ins.board.n_strings == 0 do continue
		next := len(line) == 0 ? ins.name : fmt.tprintf("%s, %s", line, ins.name)
		if text_width(next) > box.width - 20 && len(line) > 0 {
			text_centered(fmt.tprintf("%s,", line), rect(box.x, y, box.width, 12), COL_DIM)
			y += 13
			next = ins.name
		}
		line = next
	}
	if len(line) > 0 do text_centered(line, rect(box.x, y, box.width, 12), COL_DIM)
}
