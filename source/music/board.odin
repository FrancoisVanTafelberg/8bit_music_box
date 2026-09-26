package music

/*
    An instrument's fingerboard: what the editor's Helper (fingerboard.odin in
    the app) draws, and what its fingering tracker measures distances on. Like
    everything else about an instrument, it lives in the .inst file:

        board C2 G2 D3 A3                 # the open strings, lowest first (at most 6)
        board_mm 695 23 47                # string length nut to bridge, and how far apart
                                          # the outer strings are at the nut and at the
                                          # bridge (mm, from a real instrument)
        board_semis 29 20                 # semitones the board goes up the highest
                                          # string; how far up the Helper shows and the
                                          # tracker goes before calling it "too far"
        frets 0                           # 1: a fretted board (guitar): notes sit between
                                          # the frets, and the frets are drawn
        position "1st position" 1st 2 3 4 5        # a hand position: its name, a short
        position "Thumb position" Thumb 14 16 17 0 12   # label, where fingers 1-4 stop
                                          # (semitones above the open string, 0 = not
                                          # used), and optionally the thumb
        board_default 1st                 # the hand position the Helper starts on

    A keyboard instrument has a keyboard instead:

        keyboard 1                        # the Helper shows a keyboard over its range

    An instrument without a `board` line has no fingerboard (the Helper says
    so). Up to BOARD_MAX_POSITIONS positions; a block that says `position` at
    all replaces the positions it was based on.
*/

import "core:fmt"
import "core:strconv"
import "core:strings"

BOARD_MAX_STRINGS :: 6
BOARD_MAX_SEMIS :: 32
BOARD_MAX_POSITIONS :: 10

Board_Position :: struct {
	name:      [40]u8,
	name_len:  u8,
	short:     [8]u8,
	short_len: u8,
	fingers:   [4]i8, // semitones above open for fingers 1-4; 0 = not used
	thumb:     i8,
}

Board :: struct {
	strings:     [BOARD_MAX_STRINGS]i8, // open strings, MIDI, lowest first
	n_strings:   u8, // 0 = no fingerboard
	length_mm:   f32,
	nut_mm:      f32,
	bridge_mm:   f32,
	semis:       i8, // how far up the board goes
	reach:       i8, // how far up is shown and tracked before "too far"
	frets:       bool,
	positions:   [BOARD_MAX_POSITIONS]Board_Position,
	n_positions: u8,
	default_pos: u8,
	// A keyboard (piano, harpsichord, organ, celesta) instead of strings:
	// the Helper draws its keys over the instrument's range.
	keyboard:    bool,
}

board_position_name :: proc(p: ^Board_Position) -> string {return string(p.name[:p.name_len])}
board_position_short :: proc(p: ^Board_Position) -> string {return string(p.short[:p.short_len])}

// One `board...`, `frets` or `position` line into `b`. `fresh_positions`
// is cleared by the first `position` line of a block, so a block based on
// another instrument can replace its positions. Returns an error, or "".
board_line :: proc(b: ^Board, cmd: string, a: []string, fresh_positions: ^bool) -> string {
	switch cmd {
	case "board":
		if len(a) >= 1 && a[0] == "none" {b^ = {}; return ""}
		if len(a) < 1 || len(a) > BOARD_MAX_STRINGS do return "board: the open strings, lowest first, 1 to 6 of them (board E2 A2 D3 G3 B3 E4)"
		for s, i in a {
			m, ok := range_value(s)
			if !ok do return fmt.tprintf("board: '%s' is not a pitch", s)
			b.strings[i] = i8(m)
		}
		b.n_strings = u8(len(a))
		if b.semis == 0 do b.semis = 24
		if b.reach == 0 do b.reach = min(b.semis, 20)
		if b.length_mm == 0 do b.length_mm, b.nut_mm, b.bridge_mm = 650, 30, 50
	case "board_mm":
		v: [3]f32
		for i in 0 ..< 3 {
			ok: bool
			if i < len(a) do v[i], ok = strconv.parse_f32(a[i])
			if !ok || v[i] <= 0 do return "board_mm: string length, spread at the nut, spread at the bridge (mm)"
		}
		b.length_mm, b.nut_mm, b.bridge_mm = v[0], v[1], v[2]
	case "board_semis":
		n, ok1 := strconv.parse_int(a[0] if len(a) > 0 else "")
		r, ok2 := strconv.parse_int(a[1] if len(a) > 1 else "")
		if !ok1 || n < 5 || n > BOARD_MAX_SEMIS do return fmt.tprintf("board_semis: semitones on the board (5-%d) [and how far up to show]", BOARD_MAX_SEMIS)
		b.semis = i8(n)
		b.reach = ok2 ? i8(clamp(r, 5, n)) : i8(min(n, 20))
	case "frets":
		b.frets = len(a) > 0 && a[0] == "1"
	case "keyboard":
		b.keyboard = len(a) == 0 || a[0] == "1"
	case "position":
		if len(a) < 6 do return "position: \"name\" short f1 f2 f3 f4 [thumb]  (semitones above the open string, 0 = finger not used)"
		if !fresh_positions^ {
			b.n_positions = 0
			b.default_pos = 0
			fresh_positions^ = true
		}
		if int(b.n_positions) >= BOARD_MAX_POSITIONS do return fmt.tprintf("at most %d positions", BOARD_MAX_POSITIONS)
		p: Board_Position
		p.name_len = u8(copy(p.name[:], a[0]))
		p.short_len = u8(copy(p.short[:], a[1]))
		for k in 0 ..< 4 {
			v, ok := strconv.parse_int(a[2 + k])
			if !ok || v < 0 || v > BOARD_MAX_SEMIS do return "position: the four fingers are semitones above the open string, 0-32"
			p.fingers[k] = i8(v)
		}
		if len(a) > 6 {
			v, ok := strconv.parse_int(a[6])
			if ok do p.thumb = i8(clamp(v, 0, BOARD_MAX_SEMIS))
		}
		b.positions[b.n_positions] = p
		b.n_positions += 1
	case "board_default":
		if len(a) < 1 do return "board_default: the short name of a position"
		for i in 0 ..< int(b.n_positions) {
			if board_position_short(&b.positions[i]) == a[0] {b.default_pos = u8(i); return ""}
		}
		return fmt.tprintf("board_default: no position called '%s' (it must come after the position lines)", a[0])
	}
	return ""
}

// The board as `define_instrument` lines (a song that embeds the instrument).
board_write :: proc(w: ^strings.Builder, b: ^Board) {
	if b.keyboard do fmt.sbprintln(w, "keyboard 1")
	if b.n_strings == 0 do return
	buf: [8]u8
	fmt.sbprint(w, "board")
	for s in b.strings[:b.n_strings] do fmt.sbprintf(w, " %s", pitch_name(pitch_from_midi(int(s), 0), buf[:]))
	fmt.sbprintln(w)
	fmt.sbprintfln(w, "board_mm %v %v %v", b.length_mm, b.nut_mm, b.bridge_mm)
	fmt.sbprintfln(w, "board_semis %d %d", b.semis, b.reach)
	if b.frets do fmt.sbprintln(w, "frets 1")
	for i in 0 ..< int(b.n_positions) {
		p := &b.positions[i]
		fmt.sbprintf(w, "position %q %q %d %d %d %d", board_position_name(p), board_position_short(p), p.fingers[0], p.fingers[1], p.fingers[2], p.fingers[3])
		if p.thumb > 0 do fmt.sbprintf(w, " %d", p.thumb)
		fmt.sbprintln(w)
	}
	if b.n_positions > 0 do fmt.sbprintfln(w, "board_default %q", board_position_short(&b.positions[b.default_pos]))
}
