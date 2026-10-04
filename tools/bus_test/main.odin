package bus_test

/*
    Checks the mixer's buses (source/music/bus.odin), headless:

        odin run tools/bus_test          (from the project folder)

    Each check renders a few seconds through a real Mixer and measures it.
    Prints PASS or FAIL per check; exits 1 if any failed.
*/

import "core:fmt"
import "core:math"
import "core:os"
import music "../../source/music"

BLOCK :: 1024

render :: proc(m: ^music.Mixer, seconds: f32) -> []f32 {
	n := int(seconds * music.RATE) / BLOCK * BLOCK
	out := make([]f32, n * 2)
	for i := 0; i < n; i += BLOCK do music.mixer_render(m, out[i * 2:(i + BLOCK) * 2])
	return out
}

rms :: proc(s: []f32) -> f32 {
	sum: f64
	for x in s do sum += f64(x * x)
	return f32(math.sqrt(sum / f64(max(len(s), 1))))
}

peak :: proc(s: []f32) -> f32 {
	p: f32
	for x in s do p = max(p, abs(x))
	return p
}

// Energy above roughly 3 kHz: the signal less a smoothed copy of itself.
highs :: proc(s: []f32) -> f32 {
	z: f32
	k := 1 - math.exp(-math.TAU * 3000 / f32(music.RATE))
	sum: f64
	for i in 0 ..< len(s) / 2 {
		x := s[i * 2]
		z += k * (x - z)
		sum += f64((x - z) * (x - z))
	}
	return f32(math.sqrt(sum / f64(max(len(s) / 2, 1))))
}

fails := 0
check :: proc(name: string, ok: bool, detail: string) {
	fmt.printfln("%s  %-44s %s", ok ? "PASS" : "FAIL", name, detail)
	if !ok do fails += 1
}

fresh :: proc(m: ^music.Mixer) {
	music.mixer_init(m)
	music.mixer_load_instruments(m, "instruments")
	music.mixer_load_sounds(m, "sounds")
}

main :: proc() {
	if !os.is_dir("instruments") do os.set_working_directory("..")
	m: music.Mixer

	// The sfx bus at 0: the cannon is gone, a song on the music bus is not.
	fresh(&m)
	music.mixer_play_sfx(&m, "cannon")
	loud := rms(render(&m, 1))
	fresh(&m)
	music.mixer_set_bus_volume(&m, music.BUS_SFX, 0)
	music.mixer_play_sfx(&m, "cannon")
	quiet := rms(render(&m, 1))
	check("sfx bus volume 0 silences a sound effect", quiet < loud * 0.001, fmt.tprintf("%.4f -> %.6f", loud, quiet))
	song := music.mixer_play_song_file(&m, "songs/ode_to_joy.song", loop = false)
	_ = render(&m, 0.5)
	check("...and leaves the music bus playing", rms(render(&m, 1)) > 0.005 && song != 0, "")

	// The low-pass takes the highs out.
	fresh(&m)
	music.mixer_play_sfx(&m, "musket")
	open_ := highs(render(&m, 0.5))
	fresh(&m)
	music.mixer_set_bus_low_pass(&m, music.BUS_SFX, 500)
	music.mixer_play_sfx(&m, "musket")
	muffled := highs(render(&m, 0.5))
	check("low-pass at 500 Hz muffles the musket", muffled < open_ * 0.35, fmt.tprintf("highs %.4f -> %.4f", open_, muffled))

	// The echo: something heard again after the sound itself has died.
	fresh(&m)
	music.mixer_play_note(&m, "snare", 60, 0.05, bus = music.BUS_SFX)
	dry := render(&m, 0.6)
	fresh(&m)
	music.mixer_set_bus_echo(&m, music.BUS_SFX, 0.3, 0.4, 0.5)
	music.mixer_play_note(&m, "snare", 60, 0.05, bus = music.BUS_SFX)
	wet := render(&m, 0.6)
	from, to := 13230 * 2, 17640 * 2 // 0.3 s .. 0.4 s
	check("echo repeats the sound 0.3 s later", rms(wet[from:to]) > rms(dry[from:to]) * 5 + 1e-4, fmt.tprintf("%.5f vs dry %.5f", rms(wet[from:to]), rms(dry[from:to])))

	// The limiter: 300 cannons at once never pass the threshold...
	fresh(&m)
	for _ in 0 ..< 300 do music.mixer_play_sfx(&m, "cannon")
	lim := render(&m, 0.5)
	red := music.mixer_limiter_reduction(&m)
	check("limiter keeps 300 cannons under -1 dB", peak(lim) <= 0.8901, fmt.tprintf("peak %.3f", peak(lim)))
	_ = red
	// ...and off, they clip.
	fresh(&m)
	music.mixer_set_limiter(&m, false)
	for _ in 0 ..< 300 do music.mixer_play_sfx(&m, "cannon")
	check("limiter off: the same clips at full scale", peak(render(&m, 0.5)) >= 0.999, "")
	// A quiet sound goes through untouched.
	fresh(&m)
	music.mixer_play_sfx(&m, "sword_draw")
	a := render(&m, 0.5)
	fresh(&m)
	music.mixer_set_limiter(&m, false)
	music.mixer_play_sfx(&m, "sword_draw")
	b := render(&m, 0.5)
	diff: f32
	for i in 0 ..< len(a) do diff = max(diff, abs(a[i] - b[i]))
	check("limiter leaves a quiet sound alone", diff < 1e-6, fmt.tprintf("max difference %.2e", diff))

	// Buses by name; the pan is a balance.
	fresh(&m)
	battle, ok := music.mixer_bus_create(&m, "battle")
	again, _ := music.mixer_bus_create(&m, "battle")
	check("a bus by name, made once", ok && battle == again && battle > music.BUS_UI, fmt.tprintf("bus %d", battle))
	music.mixer_set_bus_pan(&m, battle, -1)
	music.mixer_play_sfx(&m, "cannon", bus = battle)
	lr := render(&m, 0.5)
	l, r: f64
	for i in 0 ..< len(lr) / 2 {l += f64(abs(lr[i * 2])); r += f64(abs(lr[i * 2 + 1]))}
	check("bus pan -1: left only", r < l * 0.001 && l > 0, fmt.tprintf("L %.1f R %.3f", l, r))
	// Destroyed: what was on it plays on the master.
	h := music.mixer_play_sfx(&m, "cannon", bus = battle)
	music.mixer_bus_destroy(&m, battle)
	_, still := music.mixer_bus_find(&m, "battle")
	check("destroyed bus: its sounds carry on on the master", !still && music.mixer_sfx_playing(&m, h) && rms(render(&m, 0.3)) > 0.001, "")

	// A custom effect: here, flipping the polarity.
	fresh(&m)
	flip :: proc(s: []f32, data: rawptr) {for &x in s do x = -x}
	music.mixer_play_sfx(&m, "cannon")
	plain := render(&m, 0.2)
	fresh(&m)
	music.mixer_set_bus_effect(&m, music.BUS_SFX, flip)
	music.mixer_play_sfx(&m, "cannon")
	flipped := render(&m, 0.2)
	same := true
	for i in 0 ..< len(plain) do if abs(plain[i] + flipped[i]) > 1e-5 {same = false; break}
	check("a custom effect runs on the bus", same, "")

	music.mixer_destroy(&m)
	fmt.printfln("\n%s", fails == 0 ? "all passed" : fmt.tprintf("%d FAILED", fails))
	if fails > 0 do os.exit(1)
}
