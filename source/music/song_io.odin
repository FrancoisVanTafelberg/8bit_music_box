package music

/*
    The .song format. See DESIGN.md section 5 for the full description.

    One statement per line; `#` starts a comment; strings are in double
    quotes. The loader is forgiving about what it does not know (a warning, and
    the line is skipped) and strict about what it does (a bad number in a note
    is an error with a line number), which is the combination that lets old
    builds open new files without letting typos through silently.
*/

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

SONG_FORMAT :: 1
SONG_EXT :: ".song"

song_to_string :: proc(s: ^Song, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	w := &b
	fmt.sbprintln(w, "# 8-Bit Music Box song")
	fmt.sbprintfln(w, "format %d", SONG_FORMAT)
	fmt.sbprintfln(w, "title %q", s.title)
	fmt.sbprintfln(w, "tempo %v", s.tempo)
	fmt.sbprintfln(w, "time %d/%d", s.beats, s.beat_unit)
	fmt.sbprintfln(w, "key %d            # %s", s.key, key_name(int(s.key)))
	fmt.sbprintfln(w, "bars %d", s.bars)
	// Instruments the song carries with it, before the tracks that use them.
	for &d in s.defs {
		fmt.sbprintln(w)
		inst_write(w, &d)
	}
	for &t in s.tracks {
		if t.metronome do continue // the editor makes it; not part of the song
		fmt.sbprintln(w)
		fmt.sbprintfln(w, "track %q", t.name)
		fmt.sbprintfln(w, "instrument %s", inst_get(s, t.inst).key)
		fmt.sbprintfln(w, "volume %.3f", t.volume)
		fmt.sbprintfln(w, "pan %.3f", t.pan)
		fmt.sbprintfln(w, "mute %d", t.mute ? 1 : 0)
		fmt.sbprintfln(w, "solo %d", t.solo ? 1 : 0)
		if t.color[3] != 0 do fmt.sbprintfln(w, "color %d %d %d", t.color[0], t.color[1], t.color[2])
		fmt.sbprintln(w, "# note  tick  length  pitch  velocity   (24 ticks = one quarter)")
		buf: [8]u8
		for n in t.notes {
			fmt.sbprintfln(w, "note %d %d %s %d", n.tick, n.len, pitch_name(n.pitch, buf[:]), n.vel)
		}
		fmt.sbprintln(w, "end")
	}
	return strings.to_string(b)
}

song_save :: proc(s: ^Song, path: string) -> bool {
	text := song_to_string(s, context.temp_allocator)
	return os.write_entire_file(path, text) == nil
}

// What went wrong (or oddly) while loading, one line each.
Load_Report :: struct {
	errors:   [dynamic]string,
	warnings: [dynamic]string,
}

report_destroy :: proc(r: ^Load_Report) {
	for e in r.errors do delete(e)
	for w in r.warnings do delete(w)
	delete(r.errors)
	delete(r.warnings)
	r^ = {}
}

song_load :: proc(path: string, out: ^Song, rep: ^Load_Report) -> bool {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		append(&rep.errors, fmt.aprintf("%s: could not read (%v)", path, err))
		return false
	}
	defer delete(data)
	return song_parse(string(data), out, rep, path)
}

song_parse :: proc(text: string, out: ^Song, rep: ^Load_Report, name := "song") -> bool {
	s: Song
	song_init(&s)
	cur: ^Track = nil
	ok := true

	// Resolved at the end, once every define_instrument block has been read,
	// so a song may define its instruments anywhere in the file.
	Pending :: struct {
		key:     string,
		line_no: int,
		pan_set: bool,
	}
	pending := make([dynamic]Pending, context.temp_allocator)
	blocks := make([dynamic]Inst_Block, context.temp_allocator)
	in_def: ^Inst_Block = nil
	bad :: proc(rep: ^Load_Report, name: string, line_no: int, msg: string) {
		append(&rep.errors, fmt.aprintf("%s:%d: %s", name, line_no, msg))
	}

	lines := text
	line_no := 0
	for raw in strings.split_lines_iterator(&lines) {
		line_no += 1

		// Inside a define_instrument block every line is the instrument's.
		if in_def != nil {
			f, nf := statement_fields(raw)
			if nf == 0 do continue
			if f[0] == "end" {
				in_def = nil
			} else {
				append(&in_def.lines, Inst_Line{no = line_no, cmd = strings.clone(f[0], context.temp_allocator), args = clone_args(f[1:nf])})
			}
			continue
		}
		line := raw
		if hash := index_outside_quotes(line, '#'); hash >= 0 do line = line[:hash]
		line = strings.trim_space(line)
		if len(line) == 0 do continue

		fields: [8]string
		nf := split_fields(line, fields[:])
		if nf == 0 do continue
		cmd := fields[0]
		args := fields[1:nf]

		switch cmd {
		case "define_instrument":
			if len(args) < 1 {bad(rep, name, line_no, "define_instrument needs a key"); ok = false; continue}
			append(&blocks, Inst_Block{key = strings.clone(args[0], context.temp_allocator), line_no = line_no})
			in_def = &blocks[len(blocks) - 1]
		case "format":
			if len(args) < 1 {bad(rep, name, line_no, "format needs a number"); ok = false; continue}
			v, _ := strconv.parse_int(args[0])
			if v > SONG_FORMAT {
				bad(rep, name, line_no, fmt.tprintf("written by a newer build (format %d, this reads %d)", v, SONG_FORMAT))
				song_destroy(&s)
				return false
			}
		case "title":
			if len(args) >= 1 do song_set_title(&s, args[0])
		case "tempo":
			if v, pok := strconv.parse_f32(args[0] if len(args) > 0 else ""); pok && v > 0 {
				s.tempo = clamp(v, 10, 400)
			} else {bad(rep, name, line_no, "tempo needs a positive number"); ok = false}
		case "time":
			parts := strings.split(args[0] if len(args) > 0 else "", "/", context.temp_allocator)
			n, a := 0, 0
			pok := len(parts) == 2
			if pok {
				n, _ = strconv.parse_int(parts[0])
				a, _ = strconv.parse_int(parts[1])
				pok = n >= 1 && n <= 16 && (a == 2 || a == 4 || a == 8 || a == 16)
			}
			if pok {
				s.beats, s.beat_unit = i32(n), i32(a)
			} else {bad(rep, name, line_no, "time must look like 4/4, 3/4, 6/8"); ok = false}
		case "key":
			v, pok := strconv.parse_int(args[0] if len(args) > 0 else "")
			if pok && v >= -7 && v <= 7 {s.key = i32(v)} else {bad(rep, name, line_no, "key must be -7..7"); ok = false}
		case "bars":
			v, pok := strconv.parse_int(args[0] if len(args) > 0 else "")
			if pok && v > 0 do s.bars = i32(min(v, 9999))
		case "track":
			append(&s.tracks, Track{name = strings.clone(args[0] if len(args) > 0 else "Track"), inst = default_inst(), volume = 0.8})
			cur = &s.tracks[len(s.tracks) - 1]
			append(&pending, Pending{key = "violin"})
		case "instrument", "volume", "pan", "mute", "solo", "color", "colour", "note":
			if cur == nil {bad(rep, name, line_no, fmt.tprintf("'%s' before any 'track'", cmd)); ok = false; continue}
			switch cmd {
			case "instrument":
				pd := &pending[len(pending) - 1]
				pd.key = strings.clone(args[0] if len(args) > 0 else "", context.temp_allocator)
				pd.line_no = line_no
			case "volume":
				if v, pok := strconv.parse_f32(args[0] if len(args) > 0 else ""); pok do cur.volume = clamp(v, 0, 2)
			case "pan":
				if v, pok := strconv.parse_f32(args[0] if len(args) > 0 else ""); pok {
					cur.pan = clamp(v, -1, 1)
					pending[len(pending) - 1].pan_set = true
				}
			case "mute":
				cur.mute = len(args) > 0 && args[0] == "1"
			case "solo":
				cur.solo = len(args) > 0 && args[0] == "1"
			case "color", "colour":
				// The layer's own colour, r g b.
				if len(args) < 3 {bad(rep, name, line_no, "color: r g b"); continue}
				for k in 0 ..< 3 {
					v, _ := strconv.parse_int(args[k])
					cur.color[k] = u8(clamp(v, 0, 255))
				}
				cur.color[3] = 255
			case "note":
				if len(args) < 3 {bad(rep, name, line_no, "note needs: tick length pitch [velocity]"); ok = false; continue}
				tick, ok1 := strconv.parse_int(args[0])
				length, ok2 := strconv.parse_int(args[1])
				p, ok3 := parse_pitch(args[2])
				vel := int(DEFAULT_VELOCITY)
				if len(args) >= 4 do vel, _ = strconv.parse_int(args[3])
				if !ok1 || !ok2 || !ok3 || tick < 0 || length <= 0 {
					bad(rep, name, line_no, fmt.tprintf("bad note '%s'", line))
					ok = false
					continue
				}
				append(&cur.notes, Note{tick = i32(tick), len = i32(length), pitch = p, vel = u8(clamp(vel, 1, 127))})
			}
		case "end":
			cur = nil
		case:
			append(&rep.warnings, fmt.aprintf("%s:%d: unknown statement '%s' skipped", name, line_no, cmd))
		}
	}

	if in_def != nil do bad(rep, name, in_def.line_no, "define_instrument without an 'end'")

	// The song's own instruments, in order: each may be based on the registry
	// or on one defined earlier in this song.
	Ctx :: struct {
		s: ^Song,
	}
	lookup :: proc(ctx: rawptr, key: string) -> (Instrument, bool) {
		c := (^Ctx)(ctx)
		if id, ok := inst_find(c.s, key); ok do return inst_get(c.s, id)^, true
		return {}, false
	}
	ctx := Ctx{&s}
	for &b in blocks {
		n_err := len(rep.errors)
		ins := inst_block_build(&b, lookup, &ctx, rep, name)
		if len(rep.errors) > n_err do ok = false
		ins.key = strings.clone(ins.key)
		ins.name = strings.clone(ins.name)
		ins.origin = .Song
		ins.source = ""
		replaced := false
		for &d in s.defs do if d.key == ins.key {
			delete(d.key)
			delete(d.name)
			d = ins
			replaced = true
		}
		if !replaced do append(&s.defs, ins)
		inst_block_destroy(&b)
	}

	// Now every track's instrument can be found.
	for &t, i in s.tracks {
		pd := pending[i]
		if id, found := inst_find(&s, pd.key); found {
			t.inst = id
		} else {
			t.inst = default_inst(&s)
			append(&rep.warnings, fmt.aprintf("%s:%d: unknown instrument '%s', using %s", name, pd.line_no, pd.key, inst_get(&s, t.inst).key))
		}
		if !pd.pan_set do t.pan = inst_get(&s, t.inst).pan
	}

	for &t in s.tracks do track_sort(&t)
	song_destroy(out)
	out^ = s
	return ok
}

// ---------------------------------------------------------------------------

// Where a comment starts: a `c` outside quotes that begins a word. The "begins
// a word" part matters - F#4 is a pitch, not a comment.
@(private)
index_outside_quotes :: proc(s: string, c: u8) -> int {
	q := false
	for i in 0 ..< len(s) {
		if s[i] == '"' do q = !q
		if !q && s[i] == c && (i == 0 || s[i - 1] == ' ' || s[i - 1] == '\t') do return i
	}
	return -1
}

// Whitespace-separated fields; a double-quoted field keeps its spaces (and
// loses its quotes). \" inside quotes is a literal quote, as %q writes it.
@(private)
split_fields :: proc(s: string, out: []string) -> int {
	n := 0
	i := 0
	for i < len(s) && n < len(out) {
		for i < len(s) && (s[i] == ' ' || s[i] == '\t') do i += 1
		if i >= len(s) do break
		if s[i] == '"' {
			i += 1
			b := strings.builder_make(context.temp_allocator)
			for i < len(s) && s[i] != '"' {
				if s[i] == '\\' && i + 1 < len(s) {
					i += 1
				}
				strings.write_byte(&b, s[i])
				i += 1
			}
			i += 1
			out[n] = strings.to_string(b)
		} else {
			start := i
			for i < len(s) && s[i] != ' ' && s[i] != '\t' do i += 1
			out[n] = s[start:i]
		}
		n += 1
	}
	return n
}
