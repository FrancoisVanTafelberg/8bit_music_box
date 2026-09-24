package music

/*
    Sound effects: a cannon, a musket volley, two swords meeting. Things that
    are not music, made from the same oscillators as the orchestra.

    They live in .sfx files in sounds/, as text, like the instruments:

        # An instrument only the sound effects use. Same grammar as a .inst
        # file; based_on can name one of these or any orchestra instrument.
        define_instrument boom
        wave triangle
        envelope 0.001 0.9 0 0.2
        sweep 14 0.06
        end

        define_sfx cannon
        name "Cannon"
        volume 1
        # voice <instrument> <pitch> <start s> <length s> [volume] [pan]
        voice boom  A1   0     0.8
        voice blast C3   0     0.5  0.9
        voice crack G6   0     0.05 0.6
        end

    A sound effect is a handful of VOICES: an instrument at a pitch, starting
    `start` seconds in and held for `length` seconds (a struck instrument, with
    sustain 0, rings for its own decay whatever the length). The pitch is a
    note name (A1, F#6), a MIDI number (33), or a frequency (440hz). For a noise
    instrument the pitch sets how bright the hiss is.

    Instruments defined in .sfx files are kept apart from the orchestra, so
    they do not turn up in the editor's instrument list.

    Played through the Mixer: mixer_play_sfx(&m, "cannon").
*/

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

SFX_EXT :: ".sfx"
SFX_DIR :: "sounds"

Sfx_Voice :: struct {
	// A copy: the voice plays this sound even if the files are reloaded.
	ins:    Instrument,
	midi:   f32,
	start:  f32, // seconds
	length: f32, // seconds held
	volume: f32,
	pan:    f32,
}

Sfx :: struct {
	key:    string,
	name:   string,
	volume: f32,
	voices: [dynamic]Sfx_Voice,
	source: string, // the .sfx file
}

Sfx_Bank :: struct {
	// The sound effects' own instruments.
	insts:   Registry,
	list:    [dynamic]Sfx,
	strings: [dynamic]string,
}

sfx_bank_destroy :: proc(b: ^Sfx_Bank) {
	registry_destroy(&b.insts)
	for &s in b.list do delete(s.voices)
	delete(b.list)
	for s in b.strings do delete(s)
	delete(b.strings)
	b^ = {}
}

sfx_find :: proc(b: ^Sfx_Bank, key: string) -> (^Sfx, bool) {
	for &s in b.list do if s.key == key do return &s, true
	return nil, false
}

// Read every .sfx file in `dir`, replacing whatever the bank held. `orchestra`
// is where `based_on` and `voice` look for an instrument after the sound
// effects' own. Returns how many sound effects were defined.
sfx_bank_load_dir :: proc(b: ^Sfx_Bank, orchestra: ^Registry, dir: string, rep: ^Load_Report) -> int {
	sfx_bank_destroy(b)

	insts := make([dynamic]Pending_Block, context.temp_allocator)
	effects := make([dynamic]Pending_Block, context.temp_allocator)
	for path in data_files(dir, SFX_EXT) {
		data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
		if rerr != nil {
			append(&rep.errors, fmt.aprintf("%s: could not read (%v)", path, rerr))
			continue
		}
		blocks := make([dynamic]Inst_Block, context.temp_allocator)
		inst_blocks_parse(string(data), &blocks, rep, file_name(path), allow_sfx = true)
		for blk in blocks {
			append(blk.kind == .Sfx ? &effects : &insts, pending_block(blk, file_name(path)))
		}
	}
	defer {
		for &p in insts do inst_block_destroy(&p.block)
		for &p in effects do inst_block_destroy(&p.block)
	}
	registry_build(&b.insts, orchestra, insts[:], rep)

	own :: proc(b: ^Sfx_Bank, s: string) -> string {
		c := strings.clone(s)
		append(&b.strings, c)
		return c
	}
	find_inst :: proc(b: ^Sfx_Bank, orchestra: ^Registry, key: string) -> (Instrument, bool) {
		if id, ok := registry_find(&b.insts, key); ok do return b.insts.list[id], true
		if orchestra != nil {
			if id, ok := registry_find(orchestra, key); ok do return orchestra.list[id], true
		}
		return {}, false
	}
	num :: proc(args: []string, i: int, def: f32) -> (f32, bool) {
		if i >= len(args) do return def, true
		return strconv.parse_f32(args[i])
	}

	for &p in effects {
		where_ := p.file
		fx := Sfx {
			key    = own(b, p.block.key),
			volume = 1,
			source = own(b, p.file),
		}
		name := ""
		for l in p.block.lines {
			a := l.args
			switch l.cmd {
			case "name":
				if len(a) >= 1 do name = a[0]
			case "volume":
				if v, ok := num(a, 0, 1); ok && len(a) > 0 do fx.volume = v
				else do append(&rep.errors, fmt.aprintf("%s:%d: volume needs a number", where_, l.no))
			case "voice":
				if len(a) < 4 {
					append(&rep.errors, fmt.aprintf("%s:%d: voice <instrument> <pitch> <start> <length> [volume] [pan]", where_, l.no))
					continue
				}
				ins, found := find_inst(b, orchestra, a[0])
				if !found {
					append(&rep.errors, fmt.aprintf("%s:%d: voice: no instrument '%s'", where_, l.no, a[0]))
					continue
				}
				midi, pok := sfx_pitch(a[1])
				start, sok := num(a, 2, 0)
				length, lok := num(a, 3, 0.1)
				vol, vok := num(a, 4, 1)
				pan, panok := num(a, 5, 0)
				if !(pok && sok && lok && vok && panok) {
					append(&rep.errors, fmt.aprintf("%s:%d: voice: pitch is a note (A1), MIDI number or 440hz; start, length, volume and pan are numbers", where_, l.no))
					continue
				}
				append(&fx.voices, Sfx_Voice{ins = ins, midi = midi, start = max(start, 0), length = max(length, 0.001), volume = vol, pan = clamp(pan, -1, 1)})
			case:
				append(&rep.warnings, fmt.aprintf("%s:%d: unknown sound effect setting '%s' skipped", where_, l.no, l.cmd))
			}
		}
		fx.name = own(b, name != "" ? name : pretty_key(fx.key))
		if len(fx.voices) == 0 do append(&rep.warnings, fmt.aprintf("%s:%d: sound effect '%s' has no voices", where_, p.block.line_no, fx.key))
		// A later definition of the same key replaces the earlier one.
		if old, ok := sfx_find(b, fx.key); ok {
			delete(old.voices)
			old^ = fx
		} else {
			append(&b.list, fx)
		}
	}
	// The instruments' voices hold copies, whose strings belong to the
	// registries: fine, both live as long as the bank.
	return len(b.list)
}

// How long a sound effect lasts, release included, in seconds.
sfx_duration :: proc(fx: ^Sfx) -> f32 {
	d: f32
	for v in fx.voices {
		end := v.start + v.length + max(v.ins.release, 0.005)
		if v.ins.sustain <= 0 do end = max(end, v.start + v.ins.attack + v.ins.decay)
		d = max(d, end)
	}
	return d
}

// Render one sound effect on its own, for the render tool and tests.
render_sfx :: proc(fx: ^Sfx, crush := true, allocator := context.allocator) -> []f32 {
	frames := int(sfx_duration(fx) * RATE) + 256
	out := make([]f32, frames * 2, allocator)
	for sv in fx.voices {
		ev := sfx_event(sv, fx.volume, 0, 0, 0)
		v := voice_make(ev, sv.ins)
		voice_render(&v, out[ev.start * 2:], crush, 1, 1, 1, 0)
	}
	for &s in out do s = clamp(s * MASTER, -1, 1)
	return out
}

// The note a voice plays, `pitch` semitones off, starting `at` frames in.
@(private)
sfx_event :: proc(sv: Sfx_Voice, volume, pan, pitch: f32, at: int) -> Event {
	return Event {
		start = at + int(sv.start * RATE),
		gate  = max(int(sv.length * RATE), 16),
		midi  = sv.midi + pitch,
		amp   = sv.volume * volume * sv.ins.gain,
		pan   = clamp(sv.pan + pan, -1, 1),
		track = -1,
	}
}

// "A1", "33", "440hz" -> MIDI note (fractional for a frequency).
sfx_pitch :: proc(s: string) -> (f32, bool) {
	low := strings.to_lower(s, context.temp_allocator)
	if strings.has_suffix(low, "hz") {
		hz, ok := strconv.parse_f32(low[:len(low) - 2])
		if !ok || hz <= 0 do return 0, false
		return 69 + 12 * math.log2(hz / 440), true
	}
	if v, ok := strconv.parse_f32(s); ok do return v, true
	if p, ok := parse_pitch(s); ok do return f32(pitch_midi(p)), true
	return 0, false
}
