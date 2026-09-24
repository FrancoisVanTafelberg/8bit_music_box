package music

/*
    Instrument definitions as text: the instruments/ (the .inst files) files, and the
    `define_instrument` blocks inside a .song. One grammar for both.

        define_instrument bugle          # the key songs refer to it by
        based_on trumpet                 # optional: start from another instrument
        name "Bugle"
        family brass                     # strings woodwinds brass percussion keyboards voices chip
        range C4 C6                      # sounding; pitch names or MIDI numbers
        wave pulse 0.5                   # pulse <duty> | triangle | saw | sine | noise
        layer triangle 0.3 12            # second oscillator: <wave> <mix 0..1> <semitones up>; "layer none"
        envelope 0.02 0.1 0.8 0.06       # attack decay sustain release (seconds, level)
        vibrato 5 0.1 0.2                # rate Hz, depth semitones, delay seconds
        sweep -0.5 0.03                  # start offset semitones, glide time
        breath 0.02                      # white noise mixed in
        tone 0.7                         # low-pass, 1 = open
        metallic 0                       # noise only: the NES "short" mode
        gain 0.5
        pan 0.2                          # -1 left .. +1 right
        color 255 200 80
        end

    Every line after the first is optional. A block starts from, in order: its
    `based_on` instrument; the existing instrument with the same key (so a later
    file can change ONE thing about the violin, `define_instrument violin` /
    `gain 0.4` / `end`); or a plain square wave.
*/

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

INST_EXT :: ".inst"
INST_DIR :: "instruments"
// A file whose name starts with this is not loaded: a way to switch one off.
INST_SKIP_PREFIX :: "_"

// What a brand-new instrument with nothing said about it sounds like.
DEFAULT_INSTRUMENT :: Instrument {
	family  = .Chip,
	lo      = 36,
	hi      = 96,
	wave    = .Pulse,
	duty    = 0.5,
	attack  = 0.005,
	decay   = 0.1,
	sustain = 0.8,
	release = 0.05,
	tone    = 1,
	gain    = 0.5,
	color   = {200, 200, 200, 255},
}

WAVE_NAME := [Wave]string {
	.Pulse    = "pulse",
	.Triangle = "triangle",
	.Saw      = "saw",
	.Sine     = "sine",
	.Noise    = "noise",
}

// Everything one block said, as its lines: the parser works on these after
// the whole block is read, so `based_on` can come anywhere in it.
Inst_Block :: struct {
	kind:    Block_Kind,
	key:     string,
	line_no: int,
	lines:   [dynamic]Inst_Line,
}

Block_Kind :: enum u8 {
	Instrument, // define_instrument
	Sfx,        // define_sfx: only in .sfx files, see sfx.odin
}

Inst_Line :: struct {
	no:   int,
	cmd:  string,
	args: []string,
}

// Turn a block into an instrument. `lookup` finds a base by key (the song's
// own definitions, then the registry). Problems go to `rep`, prefixed `where`.
inst_block_build :: proc(
	b: ^Inst_Block,
	lookup: proc(ctx: rawptr, key: string) -> (Instrument, bool),
	ctx: rawptr,
	rep: ^Load_Report,
	where_: string,
) -> Instrument {
	ins := DEFAULT_INSTRUMENT
	base_found := false
	for l in b.lines {
		if l.cmd != "based_on" do continue
		if len(l.args) < 1 {
			append(&rep.errors, fmt.aprintf("%s:%d: based_on needs an instrument key", where_, l.no))
			continue
		}
		if base, ok := lookup(ctx, l.args[0]); ok {
			ins = base
			base_found = true
		} else {
			append(&rep.errors, fmt.aprintf("%s:%d: based_on '%s': no such instrument", where_, l.no, l.args[0]))
		}
	}
	if !base_found {
		if same, ok := lookup(ctx, b.key); ok do ins = same
	}
	ins.key = b.key
	name_set := false

	bad :: proc(rep: ^Load_Report, where_: string, no: int, msg: string) {
		append(&rep.errors, fmt.aprintf("%s:%d: %s", where_, no, msg))
	}
	num :: proc(args: []string, i: int, v: ^f32) -> bool {
		if i >= len(args) do return false
		f, ok := strconv.parse_f32(args[i])
		if ok do v^ = f
		return ok
	}

	for l in b.lines {
		a := l.args
		switch l.cmd {
		case "based_on":
		case "name":
			if len(a) >= 1 {ins.name = a[0]; name_set = true}
		case "family":
			found := false
			if len(a) >= 1 do for n, f in FAMILY_NAME do if strings.to_lower(n, context.temp_allocator) == strings.to_lower(a[0], context.temp_allocator) {ins.family = f; found = true}
			if !found do bad(rep, where_, l.no, "family must be one of strings woodwinds brass percussion keyboards voices chip")
		case "range":
			lo, ok1 := range_value(a[0] if len(a) > 0 else "")
			hi, ok2 := range_value(a[1] if len(a) > 1 else "")
			if ok1 && ok2 && lo <= hi {ins.lo, ins.hi = lo, hi} else do bad(rep, where_, l.no, "range needs two pitches, low then high: range C4 C6 (or MIDI numbers)")
		case "wave":
			w, ok := wave_from(a[0] if len(a) > 0 else "")
			if !ok {bad(rep, where_, l.no, "wave must be pulse triangle saw sine or noise"); continue}
			ins.wave = w
			num(a, 1, &ins.duty)
		case "layer":
			if len(a) >= 1 && a[0] == "none" {ins.mix2 = 0; continue}
			w, ok := wave_from(a[0] if len(a) > 0 else "")
			if !ok {bad(rep, where_, l.no, "layer: <wave> <mix> <semitones>, or layer none"); continue}
			ins.wave2 = w
			num(a, 1, &ins.mix2)
			num(a, 2, &ins.semis2)
		case "envelope":
			if !(num(a, 0, &ins.attack) && num(a, 1, &ins.decay) && num(a, 2, &ins.sustain) && num(a, 3, &ins.release)) {
				bad(rep, where_, l.no, "envelope: attack decay sustain release")
			}
		case "vibrato":
			if !(num(a, 0, &ins.vib_rate) && num(a, 1, &ins.vib_depth)) do bad(rep, where_, l.no, "vibrato: rate depth [delay]")
			num(a, 2, &ins.vib_delay)
		case "sweep":
			if !num(a, 0, &ins.sweep) do bad(rep, where_, l.no, "sweep: semitones [time]")
			num(a, 1, &ins.sweep_time)
		case "breath":
			if !num(a, 0, &ins.breath) do bad(rep, where_, l.no, "breath needs a number")
		case "tone":
			if !num(a, 0, &ins.tone) do bad(rep, where_, l.no, "tone needs a number")
		case "gain":
			if !num(a, 0, &ins.gain) do bad(rep, where_, l.no, "gain needs a number")
		case "pan":
			if !num(a, 0, &ins.pan) do bad(rep, where_, l.no, "pan needs a number")
		case "metallic":
			ins.metallic = len(a) > 0 && a[0] == "1"
		case "color", "colour":
			if len(a) < 3 {bad(rep, where_, l.no, "color: r g b"); continue}
			for k in 0 ..< 3 {
				v, _ := strconv.parse_int(a[k])
				ins.color[k] = u8(clamp(v, 0, 255))
			}
			ins.color[3] = 255
		case:
			append(&rep.warnings, fmt.aprintf("%s:%d: unknown instrument setting '%s' skipped", where_, l.no, l.cmd))
		}
	}
	if !name_set && !base_found && ins.name == "" do ins.name = pretty_key(b.key)
	if !name_set && base_found do ins.name = pretty_key(b.key)
	ins.tone = clamp(ins.tone, 0.01, 1)
	ins.mix2 = clamp(ins.mix2, 0, 1)
	ins.lo = clamp(ins.lo, MIDI_LO, MIDI_HI)
	ins.hi = clamp(ins.hi, ins.lo, MIDI_HI)
	return ins
}

// The lines' strings are temp-allocated with the parse; only the list is ours.
inst_block_destroy :: proc(b: ^Inst_Block) {
	delete(b.lines)
}

// Write one instrument as a `define_instrument` block.
inst_write :: proc(w: ^strings.Builder, ins: ^Instrument) {
	buf: [8]u8
	lo := pitch_name(pitch_from_midi(int(ins.lo), 0), buf[:])
	lo_s := strings.clone(lo, context.temp_allocator)
	hi := pitch_name(pitch_from_midi(int(ins.hi), 0), buf[:])
	fmt.sbprintfln(w, "define_instrument %s", ins.key)
	fmt.sbprintfln(w, "name %q", ins.name)
	fmt.sbprintfln(w, "family %s", strings.to_lower(FAMILY_NAME[ins.family], context.temp_allocator))
	fmt.sbprintfln(w, "range %s %s", lo_s, hi)
	if ins.wave == .Pulse {
		fmt.sbprintfln(w, "wave pulse %v", ins.duty)
	} else {
		fmt.sbprintfln(w, "wave %s", WAVE_NAME[ins.wave])
	}
	if ins.mix2 > 0 {
		fmt.sbprintfln(w, "layer %s %v %v", WAVE_NAME[ins.wave2], ins.mix2, ins.semis2)
	} else {
		fmt.sbprintln(w, "layer none")
	}
	fmt.sbprintfln(w, "envelope %v %v %v %v", ins.attack, ins.decay, ins.sustain, ins.release)
	fmt.sbprintfln(w, "vibrato %v %v %v", ins.vib_rate, ins.vib_depth, ins.vib_delay)
	fmt.sbprintfln(w, "sweep %v %v", ins.sweep, ins.sweep_time)
	fmt.sbprintfln(w, "breath %v", ins.breath)
	fmt.sbprintfln(w, "tone %v", ins.tone)
	fmt.sbprintfln(w, "metallic %d", ins.metallic ? 1 : 0)
	fmt.sbprintfln(w, "gain %v", ins.gain)
	fmt.sbprintfln(w, "pan %v", ins.pan)
	fmt.sbprintfln(w, "color %d %d %d", ins.color[0], ins.color[1], ins.color[2])
	fmt.sbprintln(w, "end")
}

// ---------------------------------------------------------------------------
// instruments/ (the .inst files)
// ---------------------------------------------------------------------------

// Read every .inst file in `dir` into the registry. Returns how many
// instruments were defined. Safe to call again (F7): definitions are replaced
// in place, so every Inst_Id stays valid.
//
// ORDER. Blocks may be spread over files in any order - `based_on fife` works
// whether or not the file defining the fife sorts first. Every block from every
// file is read first; then they are built as soon as what they depend on is
// built: the instrument named in `based_on`, and any earlier block (in file
// name order) with the same key - which is what lets a later file tweak an
// earlier one (`define_instrument violin` / `gain 0.4` / `end`).
registry_load_dir :: proc(r: ^Registry, dir: string, rep: ^Load_Report) -> int {
	all := make([dynamic]Pending_Block, context.temp_allocator)
	for path in data_files(dir, INST_EXT) {
		data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
		if rerr != nil {
			append(&rep.errors, fmt.aprintf("%s: could not read (%v)", path, rerr))
			continue
		}
		blocks := make([dynamic]Inst_Block, context.temp_allocator)
		inst_blocks_parse(string(data), &blocks, rep, file_name(path))
		for b in blocks do append(&all, pending_block(b, file_name(path)))
	}
	defer for &p in all do inst_block_destroy(&p.block)
	return registry_build(r, nil, all[:], rep)
}

// The files in `dir` ending in `ext` (not those starting with "_"), sorted by
// name, as full paths. Temp-allocated.
data_files :: proc(dir, ext: string) -> []string {
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil do return nil
	names := make([dynamic]string, context.temp_allocator)
	for fi in infos {
		if strings.has_prefix(fi.name, INST_SKIP_PREFIX) do continue
		if strings.has_suffix(strings.to_lower(fi.name, context.temp_allocator), ext) do append(&names, fi.name)
	}
	slice.sort(names[:])
	for &n in names do n = strings.concatenate({dir, "/", n}, context.temp_allocator)
	return names[:]
}

@(private)
file_name :: proc(path: string) -> string {
	i := strings.last_index_any(path, "/\\")
	return path[i + 1:]
}

// A parsed define_instrument block waiting to be built.
Pending_Block :: struct {
	block: Inst_Block,
	file:  string,
	base:  string, // based_on, or ""
	done:  bool,
}

pending_block :: proc(b: Inst_Block, file: string) -> Pending_Block {
	base := ""
	for l in b.lines do if l.cmd == "based_on" && len(l.args) > 0 do base = l.args[0]
	return Pending_Block{block = b, file = file, base = base}
}

// Build parsed instrument blocks into `r`, each as soon as what it depends on
// is built. `parent`, if given, is a second place to find `based_on`
// instruments (the sound effects' own instruments can be based on the
// orchestra's). Returns how many were built.
registry_build :: proc(r: ^Registry, parent: ^Registry, all: []Pending_Block, rep: ^Load_Report) -> int {
	// Is anything not yet built going to define `key`, before index `before`?
	waiting_for :: proc(all: []Pending_Block, key: string, before: int) -> bool {
		for p, i in all {
			if i >= before do break
			if !p.done && p.block.key == key do return true
		}
		return false
	}
	Ctx :: struct {
		r, parent: ^Registry,
	}
	lookup :: proc(ctx: rawptr, key: string) -> (Instrument, bool) {
		c := (^Ctx)(ctx)
		if id, ok := registry_find(c.r, key); ok do return c.r.list[id], true
		if c.parent != nil {
			if id, ok := registry_find(c.parent, key); ok do return c.parent.list[id], true
		}
		return {}, false
	}
	ctx := Ctx{r, parent}

	count := 0
	for progress := true; progress; {
		progress = false
		for &p, i in all {
			if p.done do continue
			if waiting_for(all, p.block.key, i) do continue
			if p.base != "" {
				// Built already, or never going to be: go ahead either way
				// (the second case reports "no such instrument").
				if waiting_for(all, p.base, len(all)) do continue
			}
			ins := inst_block_build(&p.block, lookup, &ctx, rep, p.file)
			ins.key = registry_own(r, ins.key)
			ins.name = registry_own(r, ins.name)
			ins.source = registry_own(r, p.file)
			ins.origin = .File
			registry_upsert(r, ins)
			p.done = true
			progress = true
			count += 1
		}
	}
	for &p in all {
		if !p.done {
			append(&rep.errors, fmt.aprintf("%s:%d: '%s' is based on '%s', which is based on it in turn", p.file, p.block.line_no, p.block.key, p.base))
		}
	}
	return count
}

@(private)
registry_own :: proc(r: ^Registry, s: string) -> string {
	c := strings.clone(s)
	append(&r.strings, c)
	return c
}

// Split text into define_instrument ... end blocks (and, with `allow_sfx`,
// define_sfx ... end). Anything outside a block is an error (a .inst file
// holds nothing else).
inst_blocks_parse :: proc(text: string, out: ^[dynamic]Inst_Block, rep: ^Load_Report, where_: string, allow_sfx := false) {
	cur: ^Inst_Block
	lines := text
	no := 0
	for raw in strings.split_lines_iterator(&lines) {
		no += 1
		f, nf := statement_fields(raw)
		if nf == 0 do continue
		switch {
		case f[0] == "define_instrument" || (allow_sfx && f[0] == "define_sfx"):
			if cur != nil do append(&rep.errors, fmt.aprintf("%s:%d: %s inside another block (missing 'end'?)", where_, no, f[0]))
			if nf < 2 {
				append(&rep.errors, fmt.aprintf("%s:%d: %s needs a key", where_, no, f[0]))
				cur = nil
				continue
			}
			kind: Block_Kind = f[0] == "define_sfx" ? .Sfx : .Instrument
			append(out, Inst_Block{kind = kind, key = strings.clone(f[1], context.temp_allocator), line_no = no})
			cur = &out[len(out) - 1]
		case f[0] == "end":
			cur = nil
		case cur == nil:
			append(&rep.errors, fmt.aprintf("%s:%d: '%s' outside a define_instrument block", where_, no, f[0]))
		case:
			append(&cur.lines, Inst_Line{no = no, cmd = strings.clone(f[0], context.temp_allocator), args = clone_args(f[1:nf])})
		}
	}
}

// ---------------------------------------------------------------------------

@(private)
wave_from :: proc(s: string) -> (Wave, bool) {
	for n, w in WAVE_NAME do if n == s do return w, true
	return .Pulse, false
}

@(private)
range_value :: proc(s: string) -> (i32, bool) {
	if v, ok := strconv.parse_int(s); ok do return i32(v), true
	if p, ok := parse_pitch(s); ok do return i32(pitch_midi(p)), true
	return 0, false
}

// "bass_drum" -> "Bass Drum"
@(private)
pretty_key :: proc(key: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	up := true
	for c in transmute([]u8)key {
		ch := c
		if ch == '_' {
			strings.write_byte(&b, ' ')
			up = true
			continue
		}
		if up && ch >= 'a' && ch <= 'z' do ch -= 32
		strings.write_byte(&b, ch)
		up = false
	}
	return strings.to_string(b)
}

// The fields of one statement line: comments stripped, quotes honoured.
statement_fields :: proc(raw: string) -> (f: [12]string, n: int) {
	line := raw
	if hash := index_outside_quotes(line, '#'); hash >= 0 do line = line[:hash]
	line = strings.trim_space(line)
	if len(line) == 0 do return
	n = split_fields(line, f[:])
	return
}

@(private)
clone_args :: proc(a: []string) -> []string {
	out := make([]string, len(a), context.temp_allocator)
	for s, i in a do out[i] = strings.clone(s, context.temp_allocator)
	return out
}
