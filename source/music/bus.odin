package music

/*
    BUSES: groups of sounds mixed together before they reach the master.

    Every song and every sound effect plays on a bus. A bus has a volume, a
    pan (a balance, as for sound effects: one side turned down, never the
    other up) and an effect, and its sounds are summed into it first; then
    each bus is added into the MASTER bus, which has the same three things
    and, last of all, a limiter.

        songs ----------------> [ music ] --\
        sound effects --------> [ sfx   ] ---+--> [ master ] -> limiter -> out
        note previews, blips -> [ ui    ] --/
        .sfx `bus battle` ----> [ battle ] -/       (made when first used)

    Four buses always exist: BUS_MASTER, BUS_MUSIC, BUS_SFX and BUS_UI. More
    are made by name - mixer_bus_create(&m, "battle"), or a `bus battle` line
    in a .sfx file, which makes it the first time that sound plays - up to
    MAX_BUSES. A sound picks its bus when it starts (the `bus` parameter of
    mixer_play_song / mixer_play_sfx / mixer_play_note; BUS_DEFAULT means
    "music" for a song, the .sfx file's own bus or "sfx" for a sound effect,
    "ui" for a note), and can be moved later (mixer_set_song_bus,
    mixer_set_sfx_bus). Destroying a bus moves what was on it to the master.

    EFFECTS. Built in, and safe across a hot reload because they are data,
    not code: a low-pass (muffled: behind a wall, under water, far off), a
    high-pass (thin: a radio, a voice through a door) and an echo (a valley,
    a stone hall). Or your own procedure (mixer_set_bus_effect) - which, being
    a pointer into the code, must be set again after a hot reload.

    THE LIMITER, on the master: when the sum of everything would go past the
    threshold (-1 dB), the whole mix is turned down just enough, at once, and
    eased back up over the release time. A hundred muskets get quieter
    together instead of crackling. mixer_set_limiter turns it off or moves
    the threshold; mixer_limiter_reduction says how hard it is working.

    Every volume and pan change is ramped across one block, so nothing clicks.
*/

import "core:math"

MAX_BUSES :: 16

// A bus, by its index. A handle to a destroyed bus plays on the master.
Bus :: distinct u8

BUS_MASTER :: Bus(0)
BUS_MUSIC :: Bus(1)
BUS_SFX :: Bus(2)
BUS_UI :: Bus(3)
BUS_DEFAULT :: Bus(255) // as a parameter: whatever the sound's own default is

Effect_Kind :: enum u8 {
	None,
	Low_Pass, // `cutoff` Hz: everything above it fades away
	High_Pass, // `cutoff` Hz: everything below it fades away
	Echo, // `delay` seconds, `feedback` 0..0.95, `mix` 0..1
	Custom, // `custom(samples, custom_data)`
}

// Your own effect: change `samples` (interleaved stereo, L R L R ...) in
// place. Called once a block, even while the bus is silent, so it can keep
// state (in `data`) without a jump when the sound comes back.
Effect_Proc :: #type proc(samples: []f32, data: rawptr)

Effect :: struct {
	kind:        Effect_Kind,
	cutoff:      f32,
	delay:       f32,
	feedback:    f32,
	mix:         f32,
	custom:      Effect_Proc,
	custom_data: rawptr,
	// State.
	z:           [2]f32, // the filters' memory, per channel
	line:        [dynamic]f32, // the echo's delay line (stereo)
	pos:         int,
}

Bus_State :: struct {
	alive:    bool,
	name:     [32]u8,
	name_len: u8,
	volume:   f32, // what it is set to
	pan:      f32,
	cur_vol:  f32, // where the ramp has got to
	cur_pan:  f32,
	effect:   Effect,
	buf:      [dynamic]f32, // its sounds, summed, this block
	peak:     f32, // the loudest sample of the last block, after its volume: a meter
}

Limiter :: struct {
	on:        bool,
	threshold: f32, // the most the mix may reach: 0.89 is -1 dB
	release:   f32, // seconds to ease back to full after turning down
	gain:      f32, // what it is applying now (1 = nothing)
	least:     f32, // the lowest gain of the last block, for a meter
}

// ---------------------------------------------------------------------------

@(private)
buses_init :: proc(m: ^Mixer) {
	for name, i in ([4]string{"master", "music", "sfx", "ui"}) {
		b := &m.buses[i]
		bus_reset(b, name)
	}
	m.limiter = {on = true, threshold = 0.89, release = 0.15, gain = 1, least = 1}
}

@(private)
buses_destroy :: proc(m: ^Mixer) {
	for &b in m.buses {
		delete(b.buf)
		delete(b.effect.line)
	}
}

@(private)
bus_reset :: proc(b: ^Bus_State, name: string) {
	delete(b.effect.line)
	buf := b.buf
	b^ = {alive = true, volume = 1, cur_vol = 1, buf = buf}
	clear(&b.buf)
	n := min(len(name), len(b.name))
	copy(b.name[:], name[:n])
	b.name_len = u8(n)
}

@(private)
bus_get :: proc(m: ^Mixer, bus: Bus) -> ^Bus_State {
	if int(bus) < MAX_BUSES && m.buses[bus].alive do return &m.buses[bus]
	return &m.buses[BUS_MASTER]
}

// The bus a sound is on, falling back to the master if that one has gone.
@(private)
bus_live :: proc(m: ^Mixer, bus: Bus) -> Bus {
	if int(bus) < MAX_BUSES && m.buses[bus].alive do return bus
	return BUS_MASTER
}

bus_name :: proc(m: ^Mixer, bus: Bus) -> string {
	b := bus_get(m, bus)
	return string(b.name[:b.name_len])
}

// A bus by name ("music", "battle"), if there is one.
mixer_bus_find :: proc(m: ^Mixer, name: string) -> (Bus, bool) {
	for &b, i in m.buses do if b.alive && string(b.name[:b.name_len]) == name do return Bus(i), true
	return BUS_MASTER, false
}

// A new bus, or the one by that name already. Volume 1, pan 0, no effect: it
// sounds exactly like the master until something is changed. Full (MAX_BUSES):
// the master, and false.
mixer_bus_create :: proc(m: ^Mixer, name: string) -> (Bus, bool) {
	if b, ok := mixer_bus_find(m, name); ok do return b, true
	for &b, i in m.buses {
		if b.alive do continue
		bus_reset(&b, name)
		return Bus(i), true
	}
	return BUS_MASTER, false
}

// Destroy a bus (not the master): what was on it plays on the master.
mixer_bus_destroy :: proc(m: ^Mixer, bus: Bus) {
	if bus == BUS_MASTER || int(bus) >= MAX_BUSES || !m.buses[bus].alive do return
	for &s in m.songs do if s.bus == bus do s.bus = BUS_MASTER
	for &s in m.sfx do if s.bus == bus do s.bus = BUS_MASTER
	b := &m.buses[bus]
	delete(b.effect.line)
	b.effect = {}
	b.alive = false
}

// 0 silent, 1 as it is; more than 1 is allowed (the limiter catches it).
// Ramped over the next block - or at once, while the bus is silent.
mixer_set_bus_volume :: proc(m: ^Mixer, bus: Bus, volume: f32) {
	b := bus_get(m, bus)
	b.volume = max(volume, 0)
	if b.peak == 0 do b.cur_vol = b.volume
}
mixer_bus_volume :: proc(m: ^Mixer, bus: Bus) -> f32 {return bus_get(m, bus).volume}

// -1 left .. +1 right, as a balance: 0 leaves the bus as it is.
mixer_set_bus_pan :: proc(m: ^Mixer, bus: Bus, pan: f32) {
	b := bus_get(m, bus)
	b.pan = clamp(pan, -1, 1)
	if b.peak == 0 do b.cur_pan = b.pan
}
mixer_bus_pan :: proc(m: ^Mixer, bus: Bus) -> f32 {return bus_get(m, bus).pan}

// The loudest sample the bus sent on in the last block (0..1 and up).
mixer_bus_peak :: proc(m: ^Mixer, bus: Bus) -> f32 {return bus_get(m, bus).peak}

// Muffle a bus: frequencies above `hz` fade away (around 800 is behind a
// wall, 300 under water). 0 turns it off.
mixer_set_bus_low_pass :: proc(m: ^Mixer, bus: Bus, hz: f32) {
	e := &bus_get(m, bus).effect
	effect_set(e, hz > 0 ? .Low_Pass : .None)
	e.cutoff = hz
}

// Thin a bus out: frequencies below `hz` fade away (around 1000 is a small
// radio). 0 turns it off.
mixer_set_bus_high_pass :: proc(m: ^Mixer, bus: Bus, hz: f32) {
	e := &bus_get(m, bus).effect
	effect_set(e, hz > 0 ? .High_Pass : .None)
	e.cutoff = hz
}

// An echo: the bus heard again `delay` seconds later (up to 2), each repeat
// `feedback` as loud as the last (0..0.95), mixed in at `mix` (0..1). A delay
// of 0 turns it off.
mixer_set_bus_echo :: proc(m: ^Mixer, bus: Bus, delay: f32, feedback: f32 = 0.35, mix: f32 = 0.35) {
	e := &bus_get(m, bus).effect
	if delay <= 0 {effect_set(e, .None); return}
	effect_set(e, .Echo)
	e.delay = clamp(delay, 0.01, 2)
	e.feedback = clamp(feedback, 0, 0.95)
	e.mix = clamp(mix, 0, 1)
	n := int(e.delay * RATE) * 2
	if len(e.line) != n {
		resize(&e.line, n)
		for &s in e.line do s = 0
		e.pos = 0
	}
}

// Your own effect on a bus (nil: none). A procedure is a pointer into the
// code: after a hot reload, set it again.
mixer_set_bus_effect :: proc(m: ^Mixer, bus: Bus, effect: Effect_Proc, data: rawptr = nil) {
	e := &bus_get(m, bus).effect
	effect_set(e, effect != nil ? .Custom : .None)
	e.custom = effect
	e.custom_data = data
}

mixer_bus_effect :: proc(m: ^Mixer, bus: Bus) -> Effect_Kind {return bus_get(m, bus).effect.kind}

// The master's limiter: on or off, and the most the mix may reach (0.89 =
// -1 dB). Off, the mix is only clipped at full scale - harsh.
mixer_set_limiter :: proc(m: ^Mixer, on: bool, threshold: f32 = 0.89) {
	m.limiter.on = on
	m.limiter.threshold = clamp(threshold, 0.1, 1)
}

// How far the limiter turned the mix down in the last block, in dB (0: not
// at all).
mixer_limiter_reduction :: proc(m: ^Mixer) -> f32 {
	return max(-20 * math.log10(max(m.limiter.least, 1e-4)), 0)
}

// Move a playing song or sound effect to another bus.
mixer_set_song_bus :: proc(m: ^Mixer, h: Song_Handle, bus: Bus) {
	if slot := slot_get(m, h); slot != nil do slot.bus = bus_live(m, bus == BUS_DEFAULT ? BUS_MUSIC : bus)
}

mixer_set_sfx_bus :: proc(m: ^Mixer, h: Sfx_Handle, bus: Bus) {
	b := bus_live(m, bus == BUS_DEFAULT ? BUS_SFX : bus)
	for &s in m.sfx do if s.handle == h do s.bus = b
}

// ---------------------------------------------------------------------------
// Running them (mixer_render)
// ---------------------------------------------------------------------------

@(private)
effect_set :: proc(e: ^Effect, kind: Effect_Kind) {
	if e.kind != kind do e.z = {}
	if kind != .Echo {
		delete(e.line)
		e.line = nil
		e.pos = 0
	}
	e.kind = kind
}

@(private)
effect_run :: proc(e: ^Effect, s: []f32) {
	frames := len(s) / 2
	switch e.kind {
	case .None:
	case .Low_Pass, .High_Pass:
		// One pole: each sample moves the memory a fraction of the way to the
		// input. That is the low-pass; the input less it, the high-pass.
		k := 1 - math.exp(-math.TAU * clamp(e.cutoff, 10, RATE / 2) / RATE)
		high := e.kind == .High_Pass
		for i in 0 ..< frames {
			for c in 0 ..< 2 {
				x := s[i * 2 + c]
				e.z[c] += k * (x - e.z[c])
				s[i * 2 + c] = high ? x - e.z[c] : e.z[c]
			}
		}
	case .Echo:
		n := len(e.line)
		if n == 0 do return
		for i in 0 ..< frames {
			for c in 0 ..< 2 {
				x := s[i * 2 + c]
				d := e.line[e.pos + c]
				e.line[e.pos + c] = x + d * e.feedback
				s[i * 2 + c] = x + d * e.mix
			}
			e.pos = (e.pos + 2) % n
		}
	case .Custom:
		if e.custom != nil do e.custom(s, e.custom_data)
	}
}

// Ramp a bus's volume and pan across the block and add `src` into `dst`
// (src may be dst: then it is scaled in place). Returns the peak sent.
@(private)
bus_send :: proc(b: ^Bus_State, src, dst: []f32) -> f32 {
	frames := len(src) / 2
	v0, v1 := b.cur_vol, b.volume
	p0, p1 := b.cur_pan, b.pan
	b.cur_vol, b.cur_pan = v1, p1
	same := raw_data(src) == raw_data(dst)
	peak: f32
	if v0 == 1 && v1 == 1 && p0 == 0 && p1 == 0 {
		// Untouched: as it is.
		for i in 0 ..< len(src) {
			if !same do dst[i] += src[i]
			peak = max(peak, abs(src[i]))
		}
		return peak
	}
	for i in 0 ..< frames {
		t := f32(i + 1) / f32(frames)
		v := v0 + (v1 - v0) * t
		p := p0 + (p1 - p0) * t
		l := src[i * 2] * v * min(1, 1 - p)
		r := src[i * 2 + 1] * v * min(1, 1 + p)
		if same {
			dst[i * 2], dst[i * 2 + 1] = l, r
		} else {
			dst[i * 2] += l
			dst[i * 2 + 1] += r
		}
		peak = max(peak, abs(l), abs(r))
	}
	return peak
}

// The last step: turn the whole mix down where it would go past the
// threshold, at once, and ease back up; then clip at full scale, which with
// the limiter on is never reached.
@(private)
limiter_run :: proc(l: ^Limiter, s: []f32) {
	l.least = 1
	if !l.on {
		for &x in s do x = clamp(x, -1, 1)
		return
	}
	k := 1 - math.exp(-1 / (max(l.release, 0.005) * RATE))
	thr := l.threshold
	for i in 0 ..< len(s) / 2 {
		x := max(abs(s[i * 2]), abs(s[i * 2 + 1]))
		need: f32 = x > thr ? thr / x : 1
		l.gain = min(l.gain + (1 - l.gain) * k, need)
		l.least = min(l.least, l.gain)
		s[i * 2] = clamp(s[i * 2] * l.gain, -1, 1)
		s[i * 2 + 1] = clamp(s[i * 2 + 1] * l.gain, -1, 1)
	}
}
