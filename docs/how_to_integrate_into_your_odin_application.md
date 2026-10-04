# How to integrate the Music Box sound engine into your Odin application

This is for anyone — a person, or an agent working in another project such as Animal
Kingdoms — who wants the Music Box's music and sound effects inside their own Odin program.

There is **no package to import from here**. You **copy the code into your project** and
change it there as you need to. The rest of this document says what to copy, how to wire
it up, and what to watch for.

---

## 1. What you get

The engine is one struct, `music.Mixer`, plus the data files it reads. With it your program
can:

- **Play songs** (`.song` files written in the Music Box):
  - several at once (music with a fanfare over it);
  - looping, fading in and out, changing volume over time;
  - layers turned on, off or up while playing, by layer name (`"Trumpet 1"`) or instrument
    (`"trumpet"`).
- **Play sound effects** (`.sfx` files): a cannon, a musket, swords, a bell, a splash.
  - Each shot varies a little, so repeats don't sound identical.
  - Each can be placed across the screen: left edge, middle, right edge.
  - Groups of variations are picked at random (ten different musket shots).
  - Bursts fire "100 muskets over 2 seconds" as one call.
- **Mix through buses:**
  - `music`, `sfx`, `ui`, and any you create (`battle`, `ambience` ...);
  - each bus has a volume, a pan and an effect: muffled, thin, echo, or your own code;
  - everything ends in a master bus with a **limiter**, so dense moments get quieter
    instead of crackling.

Everything is synthesised. There are **no audio sample files**; instruments and sounds are
small text files. The engine (package `music`) uses **only Odin's `core:` library**: no
raylib, no C. One small extra package
(`music_rl`) sends the sound to the speakers through raylib.

What you do **not** copy: the Music Box application itself (everything directly in
`source/*.odin`: the editor, the sheet, the Helper, the UI). That's a tool; your program
only needs the engine.

---

## 2. Requirements

| | |
|---|---|
| **Odin** | `dev-2026-06` or newer (`core:os` was rebuilt in 2025–26; older compilers fail with type errors in the file code) |
| **raylib** | only for `music_rl`, through Odin's bundled `vendor:raylib`. Without raylib, write your own ~50-line output instead (§10) |
| **Platforms** | anywhere Odin and raylib run. Nothing in the engine is OS-specific |

---

## 3. What to copy

Copy these from the Music Box repository into your project, keeping the two packages
**side by side** in one folder. `music_rl` imports the engine as `"../music"`.

| From (Music Box) | To (your project, for example) | Needed? |
|---|---|---|
| `source/music/` (all `.odin` files) | `source/audio/music/` | **yes**: the engine |
| `source/music_rl/output.odin` | `source/audio/music_rl/` | yes, for a raylib program |
| `instruments/*.inst` (+ `README.txt`) | `data/instruments/` (any folder) | **yes**: the orchestra, used by songs *and* sound effects |
| `sounds/*.sfx` (+ `README.txt`) | `data/sounds/` | yes, for sound effects |
| `songs/<the ones you want>.song` | `data/songs/` | for music |
| `tools/bus_test/main.odin` | optional | a headless check that buses, effects and the limiter work after your changes (§12) |

> **Never copy anything from `songs_that_cannot_be_used_for_legal_reasons/`.** Those are
> arrangements of music that isn't public domain. They must not go into another project
> or a repository.

### Files in `source/music/` and what they do

| File | What it is | Can you leave it out? |
|---|---|---|
| `mixer.odin` | **the API**: songs, layers, sound effects, `mixer_render` | no |
| `bus.odin` | buses, their effects, the limiter | no |
| `synth.odin` | the oscillators, envelopes, the per-voice synth; `Sound_Mode` | no |
| `bowed.odin` | the bowed-string physical model (32-bit mode) | no (synth uses it) |
| `instruments.odin`, `instrument_io.odin` | the `Instrument` type and the `.inst` parser | no |
| `board.odin`, `clef.odin` | fingerboard and clef data that instruments may carry | no (part of `Instrument`) |
| `song.odin`, `song_io.odin` | the song model and the `.song` parser/writer | no |
| `sfx.odin` | sound effects and the `.sfx` parser | no |
| `theory.odin` | pitches, keys, note lengths | no |
| `midi.odin` | MIDI file import | **yes**, unless you import `.mid` files |
| `wav.odin` | writing WAV files | **yes**, unless you render to disk |
| `pitch.odin`, `chord.odin` | microphone pitch and chord detection | **yes**: editor-only |

The cut-down set (without the last four) is verified to compile on its own.

---

## 4. Wiring it up (raylib)

The whole lifecycle is about 20 lines:

```odin
import music    "audio/music"
import music_rl "audio/music_rl"
import rl       "vendor:raylib"

mixer: music.Mixer       // put these in your app's state block (see §5)
out:   music_rl.Output

audio_init :: proc() {
    rl.InitAudioDevice()                  // before output_open
    music.mixer_init(&mixer)

    rep: music.Load_Report
    defer music.report_destroy(&rep)
    music.mixer_load_instruments(&mixer, "data/instruments", &rep)   // first: sounds use them
    music.mixer_load_sounds(&mixer, "data/sounds", &rep)
    for e in rep.errors   do log.error(e)  // file:line: what is wrong
    for w in rep.warnings do log.warn(w)

    music_rl.output_open(&out)            // block = 1024 frames (~23 ms) by default
}

audio_update :: proc() {                  // ONCE PER FRAME, from your game loop
    music_rl.output_update(&out, &mixer)
}

audio_shutdown :: proc() {
    music_rl.output_close(&out)
    music.mixer_destroy(&mixer)
    rl.CloseAudioDevice()
}
```

Then, anywhere in your game:

```odin
march := music.mixer_play_song_file(&mixer, "data/songs/british_grenadiers.song", loop = true, fade_in = 2)
music.mixer_play_sfx_at(&mixer, "cannon", cannon_screen_x / screen_width)    // 0 left .. 1 right
music.mixer_stop_song(&mixer, march, fade_out = 3)
```

**`output_update` must run every frame.** It mixes a little ahead each frame and hands
raylib's audio stream a block when it asks. Skip it and the sound stops; stall the game
for longer than the buffer and you hear a gap.

---

## 5. Hot reload (Animal Kingdoms' setup)

The engine was written inside the same hot-reload arrangement as Animal Kingdoms: the
game is a DLL, all state lives in one heap block, and the host hands that block back after
swapping the DLL.

1. **Put the `Mixer` and the `Output` in your state block**, the struct the host keeps,
   never in package-level variables. They hold heap memory and a raylib stream that must
   survive the swap.
2. **After every reload, call `music.mixer_bind(&g.mixer)`.** Songs find their instruments
   through a package-level pointer, and a reloaded DLL starts with a fresh, empty one. The
   Music Box does this in `game_hot_reloaded`.
3. **Custom bus effects are procedure pointers into the old DLL.** If you set one with
   `mixer_set_bus_effect`, set it again after a reload. The built-in effects (low-pass,
   high-pass, echo) are plain data and survive.
4. **There is no audio callback on purpose.** raylib's audio thread would call into code a
   reload can unload. Polling from the game loop (`output_update`) is reload-safe.
5. If a reload **changes the layout** of `Mixer` (you edited the engine's structs), the
   memory block can't be reused. Restart, as with any layout change in your state.

---

## 6. Songs

| Call | |
|---|---|
| `mixer_play_song_file(&m, path, loop, volume, fade_in, rep, bus)` → `Song_Handle` | load and play a `.song`; 0 if it could not be read |
| `mixer_play_song(&m, &song, loop, volume, fade_in, from_tick, to_tick, bus)` | a song already in memory (start part-way, stop early) |
| `mixer_stop_song(&m, h, fade_out)`, `mixer_stop_all_songs` | fade out and stop |
| `mixer_set_song_volume(&m, h, volume, seconds)` | turn a song up or down over time |
| `mixer_set_song_loop`, `mixer_song_playing`, `mixer_song_time`, `mixer_song_title` | |
| `mixer_set_layer(&m, h, "Trumpet 1", on)` | a layer on/off by its name |
| `mixer_set_instrument(&m, h, "trumpet", on)` | every layer playing that instrument |
| `mixer_set_layer_gain`, `mixer_set_instrument_gain` | a layer's level on top of its own |
| `mixer_solo_layer`, `mixer_solo_instrument`, `mixer_set_all_layers` | |
| `mixer_layer_count`, `mixer_layer_name` | list the layers for a menu |

**Handles:**
- Every handle is safe to keep after its sound has ended: calls on it do nothing, and
  `mixer_song_playing` says false.
- 0 is never a valid handle.
- Up to 4 songs play at once (`MAX_SONGS`); a 5th replaces the one nearest to finishing.

**Changes are ramped.** Layer and volume changes glide over a block, so muting a layer
mid-song never clicks. That makes them a good tool for dynamic music, e.g. drums in when a
battle starts, trumpets out when it ends.

---

## 7. Sound effects

| Call | |
|---|---|
| `mixer_play_sfx(&m, key, volume, pan, pitch, vary, bus)` → `Sfx_Handle` | `pan` -1..1 is a **balance** (0 both ears full; -1 left only). `vary` = random pitch shift up to that many semitones, so repeats differ |
| `mixer_play_sfx_at(&m, key, x, volume, pitch, vary, bus)` | `x` = where on screen: 0 left edge, 0.5 middle, 1 right edge (`screen_pan(x)` converts) |
| `mixer_play_sfx_group(&m, group, ...)` | a random member of a group (`group musket` in the `.sfx` file: eleven musket shots) |
| `mixer_play_sfx_burst(&m, key, count, seconds, volume, pan_spread, vary, times, pan, mixed, bus)` | many shots bunched on a bell curve over `seconds`, as one handle, scaled so they don't overload; `mixed = true` picks a random group member per shot |
| `mixer_play_note(&m, inst_key, midi, seconds, volume, pan, bus)` | one note on any instrument: a UI blip, a stinger, a bell |
| `mixer_stop_sfx(&m, h, fade_out)`, `mixer_stop_all_sfx`, `mixer_sfx_playing` | |
| `mixer_sfx_count`, `mixer_sfx_key` | list what is loaded |

- Up to 640 voices sound at once (`MAX_SFX_VOICES`). A musket is 4–5 voices; when full,
  the oldest voice gives way.
- **Making new sounds** is editing text: see `sounds/README.txt` (the format, and what
  shapes make a thump, a crack, a clang) and `sounds/musket_shots.sfx` (shots fitted to
  a real recording).
- Reload the files while the game runs by calling `mixer_load_instruments` then
  `mixer_load_sounds` again; the Music Box binds this to `F7`.

---

## 8. Buses: how to set them up for a game

Every sound plays on a bus. Each bus sums its sounds, runs its effect, and adds itself into
the master with its volume and pan. The master does the same, then the limiter.

```
songs ----------------> [ music  ] --\
sound effects --------> [ sfx    ] ---+--> [ master ] -> limiter -> speakers
note previews, blips -> [ ui     ] ---|
your own -------------> [ battle ] --/
```

- **Always there:** `BUS_MASTER`, `BUS_MUSIC` (songs go here), `BUS_SFX` (sound effects),
  `BUS_UI` (`mixer_play_note`).
- **Your own, by name:** `mixer_bus_create(&m, "battle")` returns `(Bus, ok)`, up to
  `MAX_BUSES` = 16. A `bus battle` line in a `.sfx` file sends that sound there by default
  and creates the bus the first time it plays, so routing can live in the data.
- **Choose per call:** every play call takes `bus =`. `BUS_DEFAULT` means the sound's own
  default: `music` for songs, the `.sfx` file's `bus` (or `sfx`) for effects, `ui` for
  notes.
- **Move later:** `mixer_set_song_bus`, `mixer_set_sfx_bus`. `mixer_bus_destroy` sends
  whatever was on the bus to the master.
- **Options-menu sliders:** `mixer_set_bus_volume(&m, BUS_MUSIC, v)`, same for `BUS_SFX`
  and `BUS_MASTER`.
- **Pan:** `mixer_set_bus_pan` is a balance; 0 leaves the bus untouched.
- **Meters:** `mixer_bus_peak(&m, bus)` is the loudest sample of the last block.

**Effects** (one per bus; setting one replaces the last):

| Call | Sounds like |
|---|---|
| `mixer_set_bus_low_pass(&m, bus, 700)` | behind a wall (~700 Hz), under water (~300), far away |
| `mixer_set_bus_high_pass(&m, bus, 1200)` | thin: a radio, a voice through a door |
| `mixer_set_bus_echo(&m, bus, 0.32, 0.4, 0.4)` | delay seconds, feedback, mix: a valley, a stone hall |
| `mixer_set_bus_effect(&m, bus, my_proc, &my_state)` | your own: `proc(samples: []f32, data: rawptr)` on the bus's interleaved stereo block, called every block even when silent, so state carries across |
| any of the above with 0 / nil | off |

**The limiter** (on by default):
- When the whole mix would pass -1 dB, it turns the mix down at once by just enough, then
  eases back over 0.15 s.
- A quiet mix passes through bit for bit.
- `mixer_set_limiter(&m, on, threshold)` changes it; `mixer_limiter_reduction(&m)` reports
  how many dB it is turning the mix down (show it while tuning a battle).

**A suggested layout for Animal Kingdoms:**
- `music` for the score.
- `battle` for cannons, muskets and swords (add `bus battle` to those `.sfx` blocks), so a
  whole engagement can be muffled when the camera moves away (low-pass) or ducked under
  dialogue (volume).
- `ambience` for wind and water.
- `ui` for menu blips.
- Options sliders on `music`, `battle` + `ambience` (or `sfx`), and `master`.

---

## 9. Positional sound and the screen

The engine's pan for sound effects is a **balance**, matching what a player expects from a
2D screen. A sound on the left edge is 100 % left ear and 0 % right; at the middle both
ears get 100 %; neither side is ever made louder than the sound itself. So:

```odin
x01 := (world_x - camera_left) / view_width       // 0..1 across the visible screen
music.mixer_play_sfx_at(&mixer, "musket", x01, volume = distance_volume)
```

For sounds off screen, clamp `x01` to 0..1 (`screen_pan` already does) and lower `volume`
with distance, or route far-away fights to a bus with a low-pass.

---

## 10. Threads, timing, other audio outputs

**Single-threaded.** Call everything, `mixer_render` included, from one thread: your game
loop, which is what `music_rl` does. If your audio API calls back from its own thread,
either:
- keep `music_rl`'s approach (render in the loop, hand finished blocks to the callback
  through a ring buffer), or
- guard the mixer with a mutex in every call. The first is simpler and hot-reload safe.

**Latency.** About two blocks plus what is mixed ahead; `music_rl.output_latency(&out)`
gives it in seconds (~50 ms at the default block of 1024 frames). Raise the block to 2048
if your game can stall for more than ~40 ms (dragging the window on Windows does).
`out.stats.underruns` counts gaps.

**Syncing pictures to sound.** `out.sent` is a frame clock of what has been handed to the
speakers. The Music Box's `source/player.odin` uses it for its playhead.

**Without raylib.** `mixer_render(&m, block)` fills any length of interleaved stereo `f32`
at 44100 Hz. Feed that to SDL, miniaudio, WASAPI or anything else. `music_rl/output.odin`
is a ~150-line example of doing it well: mix ahead in small chunks every frame, so a busy
battle doesn't put a whole block's work into one frame.

**Rendering to a file.** `music.render_song(&song, mode)` and `music.render_sfx(&fx, mode)`
return sample arrays; `wav.odin` writes them. See `tools/render` in the Music Box.

**Sound mode.** `m.mode` (a `Sound_Mode`: 4-bit, 8-bit (default), 16-bit, 32-bit) applies
to sounds started after it is set. 16-bit adds a player's variation; 32-bit uses the bowed
string model.

---

## 11. Changing your copy

You own the copy, so change what you need. Some notes so changes stay easy:

- **Record where it came from.** Put a line at the top of your copied `mixer.odin` (or a
  `README` beside it) with the Music Box commit or date you copied. Later, a diff against
  that commit shows what upstream changed.
- **Package names.** Keep `package music` and `package music_rl` if you can. If you rename
  them, change `music_rl/output.odin`'s `import music "../music"` to match, and if you
  move the folders apart, fix that relative path.
- **Safe to change freely:** the constants at the top of `mixer.odin` (`MAX_SONGS`,
  `MAX_SFX_VOICES`), `bus.odin` (`MAX_BUSES`, the limiter defaults in `buses_init`), the
  default bus names, the data files.
- **Change with care:**
  - `synth.odin`'s `MASTER` (the headroom every voice is mixed with). Every instrument's
    loudness was balanced against it.
  - The `.inst` / `.sfx` / `.song` grammars. The Music Box writes those files, so keep
    yours compatible if you want to keep authoring sounds and songs in it.
- **Data files are the place for content.** Instruments, sounds and songs are all text, so
  your game's own sounds belong in your copies of `instruments/` and `sounds/`, not in
  code. That is a rule of the Music Box too: no instrument is defined in code.
- **The Music Box is where to author.** Write a song in the editor, save it, copy the
  `.song` across. Try a sound effect in its SFX tester (the **SFX** button: buses,
  position, bursts), then copy the `.sfx`.

---

## 12. Checklist

- [ ] `source/.../music/` and `source/.../music_rl/` copied side by side; the optional
      files dropped if unwanted.
- [ ] `instruments/`, `sounds/` and the songs you want copied; nothing from
      `songs_that_cannot_be_used_for_legal_reasons/`.
- [ ] `rl.InitAudioDevice()` → `mixer_init` → `mixer_load_instruments` →
      `mixer_load_sounds` → `output_open`, in that order.
- [ ] `output_update(&out, &mixer)` called every frame.
- [ ] `Mixer` and `Output` live in the hot-reload state block; `mixer_bind` called after
      each reload; custom effect procs re-set.
- [ ] `Load_Report` errors printed during development (a typo in a `.sfx` file is reported
      with its file and line, not silently ignored).
- [ ] Options sliders wired to `mixer_set_bus_volume`.
- [ ] Optional: copy `tools/bus_test/main.odin`, point its paths at your data, and run it
      (`odin run tools/bus_test`) after changing the engine. It checks bus volume, routing,
      pan, the effects, a custom effect and the limiter, headless.

## 13. When something is wrong

| Symptom | Likely cause |
|---|---|
| No sound at all | `output_open` before `rl.InitAudioDevice()` (it returns false); or `output_update` not being called every frame |
| Songs silent, sound effects fine | the instruments folder path is wrong (check the `Load_Report`); or after a hot reload, `mixer_bind` was not called |
| `mixer_play_sfx` returns 0 | no sound effect by that key: check `mixer_sfx_key`, and the report for parse errors |
| Gaps / stutter | the game stalled longer than the buffer: `output_open(&out, block = 2048)`; check `out.stats.underruns` |
| A crash after a hot reload | a custom bus effect still points at the old DLL: set it again after the reload |
| Harsh crackle when lots happens | the limiter was turned off (`mixer_set_limiter(&m, true)`) |
| Everything a bit quiet | it's mixed with headroom so a battle fits: raise the master bus volume (the limiter catches peaks) |
| Compile error in `music_rl` about `"../music"` | the two folders aren't side by side, or the package was renamed: fix the import path |

---

*Written for the Music Box as of its bus/limiter engine (October 2026). The authoritative
references inside the code: the comment at the top of `source/music/mixer.odin` (the API),
`source/music/bus.odin` (buses, effects, limiter), `sounds/README.txt` and
`instruments/README.txt` (the data formats), and `.design/DESIGN.md` §4.2 in the Music Box
repository.*
