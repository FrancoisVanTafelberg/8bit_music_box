package music

/*
    Standard MIDI File import.

    The reliable way to get real music onto the sheet: thousands of public
    domain classical pieces exist as .mid, and a DOSBox MIDI capture of
    Colonization would give its original score (DESIGN.md section 9).

    What happens to a file:
      * ticks are rescaled from the file's resolution to TPQ and snapped to the
        nearer of the 32nd grid (3 ticks) and the triplet grid (4 ticks);
      * one layer per (MIDI track, channel), its instrument from the General
        MIDI program; channel 10 is split into drum layers;
      * notes outside their instrument's range are moved by octaves until they
        fit, and counted, so the import can say so;
      * the first tempo, time signature and key signature win (MB-2).
*/

import "core:fmt"
import "core:os"
import "core:strings"

Midi_Report :: struct {
	notes:      int,
	layers:     int,
	transposed: int,
	message:    string, // set on failure
}

@(private = "file")
Reader :: struct {
	data: []u8,
	pos:  int,
	bad:  bool,
}

@(private = "file")
u8r :: proc(r: ^Reader) -> u8 {
	if r.pos >= len(r.data) {r.bad = true; return 0}
	r.pos += 1
	return r.data[r.pos - 1]
}

@(private = "file")
be :: proc(r: ^Reader, n: int) -> u32 {
	v: u32
	for _ in 0 ..< n do v = v << 8 | u32(u8r(r))
	return v
}

@(private = "file")
varlen :: proc(r: ^Reader) -> u32 {
	v: u32
	for _ in 0 ..< 4 {
		b := u8r(r)
		v = v << 7 | u32(b & 0x7f)
		if b & 0x80 == 0 do break
	}
	return v
}

@(private = "file")
Raw_Note :: struct {
	start, end: u32,
	key:        u8,
	vel:        u8,
}

@(private = "file")
Group :: struct {
	track, channel: int,
	name:           string,
	notes:          [dynamic]Raw_Note,
}

midi_import_file :: proc(path: string, out: ^Song) -> Midi_Report {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil do return {message = fmt.aprintf("could not read %s (%v)", path, err)}
	defer delete(data)
	title := path
	if i := strings.last_index_any(title, "/\\"); i >= 0 do title = title[i + 1:]
	if i := strings.last_index_byte(title, '.'); i > 0 do title = title[:i]
	return midi_import(data, out, title)
}

midi_import :: proc(data: []u8, out: ^Song, title: string) -> Midi_Report {
	rep: Midi_Report
	r := Reader{data = data}
	if len(data) < 14 || string(data[:4]) != "MThd" do return {message = strings.clone("not a MIDI file (no MThd header)")}
	r.pos = 4
	hlen := int(be(&r, 4))
	_ = be(&r, 2) // format
	ntracks := int(be(&r, 2))
	division := int(be(&r, 2))
	r.pos = 8 + hlen
	if division & 0x8000 != 0 || division == 0 do return {message = strings.clone("SMPTE-timed MIDI files are not supported")}

	tempo_us := -1
	ts_num, ts_den := 4, 4
	key := 0
	have_ts, have_key := false, false
	programs: [16]int
	have_program: [16]bool
	groups: [dynamic]Group
	defer {
		for &gr in groups {delete(gr.notes); delete(gr.name)}
		delete(groups)
	}

	find_group :: proc(groups: ^[dynamic]Group, track, ch: int) -> ^Group {
		for &gr in groups do if gr.track == track && gr.channel == ch do return &gr
		append(groups, Group{track = track, channel = ch})
		return &groups[len(groups) - 1]
	}

	for ti in 0 ..< ntracks {
		if r.pos + 8 > len(data) do break
		id := string(data[r.pos:r.pos + 4])
		r.pos += 4
		tlen := int(be(&r, 4))
		tend := min(r.pos + tlen, len(data))
		if id != "MTrk" {r.pos = tend; continue}

		track_name := ""
		time: u32
		status: u8
		// Held notes: [channel][key] -> start tick and velocity, or -1.
		on_start: [16][128]i64
		on_vel: [16][128]u8
		for c in 0 ..< 16 do for k in 0 ..< 128 do on_start[c][k] = -1

		for r.pos < tend && !r.bad {
			time += varlen(&r)
			b := data[r.pos] if r.pos < len(data) else 0
			if b & 0x80 != 0 {status = b; r.pos += 1}
			switch {
			case status == 0xFF:
				mtype := u8r(&r)
				mlen := int(varlen(&r))
				mstart := r.pos
				switch mtype {
				case 0x03:
					if mstart + mlen <= len(data) do track_name = string(data[mstart:mstart + mlen])
				case 0x51:
					if tempo_us < 0 do tempo_us = int(be(&r, 3))
				case 0x58:
					if !have_ts && mlen >= 2 {
						ts_num = int(data[mstart])
						ts_den = 1 << data[mstart + 1]
						have_ts = true
					}
				case 0x59:
					if !have_key && mlen >= 1 {
						key = int(i8(data[mstart]))
						have_key = true
					}
				}
				r.pos = mstart + mlen
			case status == 0xF0 || status == 0xF7:
				r.pos += int(varlen(&r))
			case:
				ch := int(status & 0x0f)
				switch status & 0xf0 {
				case 0x80, 0x90:
					k := u8r(&r) & 0x7f
					vel := u8r(&r)
					if status & 0xf0 == 0x90 && vel > 0 {
						if on_start[ch][k] >= 0 {
							// Re-struck while held: end the old one here.
							gr := find_group(&groups, ti, ch)
							append(&gr.notes, Raw_Note{u32(on_start[ch][k]), time, k, on_vel[ch][k]})
						}
						on_start[ch][k] = i64(time)
						on_vel[ch][k] = vel
					} else if on_start[ch][k] >= 0 {
						gr := find_group(&groups, ti, ch)
						append(&gr.notes, Raw_Note{u32(on_start[ch][k]), time, k, on_vel[ch][k]})
						on_start[ch][k] = -1
					}
				case 0xA0, 0xB0, 0xE0:
					r.pos += 2
				case 0xC0:
					p := int(u8r(&r))
					if !have_program[ch] {programs[ch] = p; have_program[ch] = true}
				case 0xD0:
					r.pos += 1
				case:
					r.pos += 1 // corrupt; step on rather than loop
				}
			}
		}
		for &gr in groups do if gr.track == ti && gr.name == "" && track_name != "" do gr.name = strings.clone(track_name)
		r.pos = tend
	}

	// --- Build the song ---
	s: Song
	song_init(&s)
	song_set_title(&s, title)
	if tempo_us > 0 do s.tempo = f32(int(60_000_000.0 / f64(tempo_us) + 0.5))
	if ts_den == 2 || ts_den == 4 || ts_den == 8 || ts_den == 16 {
		s.beats, s.beat_unit = i32(clamp(ts_num, 1, 16)), i32(ts_den)
	}
	s.key = i32(clamp(key, -7, 7))

	conv :: proc(t: u32, division: int) -> i32 {
		exact := f64(t) * TPQ / f64(division)
		a := i32(exact / 3 + 0.5) * 3
		b := i32(exact / 4 + 0.5) * 4
		return abs(f64(a) - exact) <= abs(f64(b) - exact) ? a : b
	}

	for &gr in groups {
		if len(gr.notes) == 0 do continue
		if gr.channel == 9 {
			// Drums: one layer per kind, at a fixed pitch that suits it.
			Kit :: struct {
				inst: Inst,
				midi: int,
			}
			kits := [3]Kit{{.Bass_Drum, 36}, {.Snare, 67}, {.Cymbals, 84}}
			idx: [3]int = {-1, -1, -1}
			for n in gr.notes {
				k := 1
				switch n.key {
				case 35, 36:
					k = 0
				case 42, 44, 46, 49, 51, 52, 53, 55, 57, 59:
					k = 2
				}
				if idx[k] < 0 do idx[k] = song_add_track(&s, kits[k].inst)
				m := kits[k].midi
				if k == 1 && n.key != 38 && n.key != 40 do m = clamp(int(n.key) + 14, 55, 79) // toms: lower, darker
				st := conv(n.start, division)
				ln := max(conv(n.end, division) - st, 3)
				append(&s.tracks[idx[k]].notes, Note{st, ln, pitch_from_midi(m, int(s.key)), max(n.vel, 1)})
				rep.notes += 1
			}
			continue
		}

		inst := inst_from_gm(programs[gr.channel])
		ins := INSTRUMENTS[inst]
		name := ""
		if gr.name != "" do name = fmt.tprintf("%s (%s)", ins.name, gr.name)
		ti := song_add_track(&s, inst, name)
		t := &s.tracks[ti]
		for n in gr.notes {
			m := int(n.key)
			if m < int(ins.lo) || m > int(ins.hi) {
				for m < int(ins.lo) do m += 12
				for m > int(ins.hi) do m -= 12
				rep.transposed += 1
			}
			st := conv(n.start, division)
			ln := max(conv(n.end, division) - st, 3)
			append(&t.notes, Note{st, ln, pitch_from_midi(m, int(s.key)), max(n.vel, 1)})
			rep.notes += 1
		}
	}
	for &t in s.tracks do track_sort(&t)
	rep.layers = len(s.tracks)
	if rep.notes == 0 {
		song_destroy(&s)
		return {message = strings.clone("the file has no notes in it")}
	}
	s.bars = 1
	song_fit_bars(&s, 4)
	song_destroy(out)
	out^ = s
	return rep
}
