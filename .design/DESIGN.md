# 8-Bit Music Box — design

A sheet-music editor and chiptune synthesiser, in Odin and raylib, for writing
(and re-creating) music as 8-bit orchestra: the Colonization soundtrack first,
then any classical piece.

This is a living document. Change it when a decision changes.

## Open questions

| id | question | blocks |
|---|---|---|
| MB-1 | Chip-strict mode: should a song be able to opt into a hard voice limit (NES: 2 pulse + 1 triangle + 1 noise at once) so it could genuinely run on the hardware? Today every note gets its own voice. | nothing yet |
| MB-2 | Tempo changes mid-song (ritardando, a new section at a new speed). Today a song has one tempo; MIDI import takes the first one. | faithful MIDI import of some pieces |
| MB-3 | Ties and notes longer than the snap grid allows (a note held across a bar line is stored fine, but there is no tie *notation*). | engraving-quality display |
| MB-4 | Dynamics: velocity is stored per note (0–127) but there is no UI for it yet. A lane under the sheet? A wheel-with-Alt on a note? | expressive playback |
| MB-5 | Audio → notes: which approach (see §8), and is it worth it once DOSBox MIDI capture (§9) gives us the original scores exactly? | audio import |

---

## 1. What it is

* One **sheet** per song. The sheet shows **4 bars at a time** (a *page*), left to right,
  like a line of printed music.
* Vertically, every bar shows the **whole playable range at once**: one continuous
  "super-staff" from A0 at the bottom to C8 at the top, with the treble and bass staves
  drawn bold where they would be on a grand staff and every other line faint. There is
  no clef switching — all the clefs are always there.
* The sheet is **not free-form**. Pitches sit on staff rows (lines and spaces);
  time snaps to slots. Pick a note length, click a slot, a note of that length drops in.
* Each **instrument is a layer** on the same sheet. Picking an instrument makes its
  layer the one you edit; every other layer is still drawn, dimmer, in its own colour.
  Rows outside the active instrument's real range are shaded and refuse clicks.
* **Play** runs a playhead across the sheet, lights up notes as they sound and turns
  the page when it reaches the edge.
* Songs are saved as **plain text** (`.song`) and exported to **WAV** (built in), and to
  **MP3 / OGG / FLAC** through ffmpeg when it is installed.
* **MIDI files import** straight onto the sheet. Audio files (WAV/MP3) are a later,
  best-effort "draft transcription" (§8).

## 2. How 8-bit sound works (and why an instrument is more than a waveform)

Consoles like the NES did not play recordings. They had a handful of **tone
generators** — tiny circuits that output one simple repeating shape at a pitch you set:

| channel | shape | sounds like |
|---|---|---|
| Pulse ×2 | a square wave with a variable **duty cycle** (12.5 %, 25 %, 50 %) | 50 % is hollow and woody (clarinet-ish); 25 % is brighter (oboe, trumpet); 12.5 % is thin and nasal |
| Triangle | a 4-bit, 16-step triangle | soft, flute-like, and the classic NES bass |
| Noise | a shift register spitting out pseudo-random bits | drums, cymbals, breath, wind. A "short" mode repeats every 93 steps and turns metallic |
| (C64 SID, VRC6) | sawtooth | bright and buzzy: strings and brass |

So yes, at the bottom an instrument *is* a waveform — but a violin and a trumpet
can both be a sawtooth and still sound different, because chip composers shaped
everything *around* the waveform:

* **Envelope (ADSR)** — how fast it starts (attack), falls (decay), holds (sustain) and
  dies (release). A harp is a sharp attack and no sustain; a horn swells in.
* **Vibrato** — a slow pitch wobble that starts a moment after the note. This is most of
  what makes a pulse wave read as "violin" or "voice".
* **Pitch sweep** — a fast slide at the start of the note. Timpani and bass drums are a
  triangle that drops in pitch.
* **Layers** — two generators at once: an organ is a pulse plus the same pulse an octave
  up; a horn is a pulse softened with a triangle; a flute is a triangle plus a little noise
  for breath.
* **Tone** — a gentle low-pass filter. Real chips did not have one (the SID did); we use it
  lightly so a cello's sawtooth is darker than a violin's.
* **Sound mode** — one button in the top bar (click: next, right-click: back), for the
  whole app and for the engine (`Mixer.mode`, `render -- -4/-8/-16/-32`). The instruments
  are the same in every mode; what changes is how they are rendered:

  | mode | what you hear |
  |---|---|
  | **4-bit** | NES channels had 16 volume levels, so fades are staircases: every envelope is quantised to 16 steps. The grittiest |
  | **8-bit** (default) | the chip oscillators with smooth volume |
  | **16-bit** | 8-bit plus a player's touch: each note a few cents off, vibrato a little faster or slower and wider or narrower note to note, a slow wander under it, a burst of bow scratch or breath chiff at the start (instruments with `breath`), and a smooth triangle instead of the 16-step one. All seeded from the note, so a song sounds the same every play |
  | **32-bit** | 16-bit plus physical models and bodies (`source/music/bowed.odin`). `model bowed`: violin, viola, cello and contrabass play a simulated bowed string — two delay lines either side of the bow, a stick-slip friction curve, a lossy bridge (McIntyre/Schumacher/Woodhouse as in STK's Bowed) — instead of a saw wave. `resonance` lines (Hz, Q, dB; up to 4): peaking filters for the wooden body's main modes and the bridge, heard in 32-bit only |

  Tuning the bowed model: drawn gently (bow speed 0.08) it settles into clean Helmholtz
  motion (a sawtooth, harmonics falling 6 dB then 9.5 dB) across the range; faster, it
  squeaks into octave modes. High up, the bridge side of the string is kept at least ~4
  samples (a player bows nearer the bridge up there) or it stops speaking; the loop's
  extra delay (1.6 samples, 1.4 above 2.4 kHz) is allowed for so it is in tune, within the
  ± few cents of 16-bit's deliberate detuning.

That is exactly what an instrument definition records (`instruments/<family>.inst`). The whole
orchestra is built from five oscillators: pulse, triangle, saw, sine, noise.

### Where instruments come from

**No instrument is defined in code.** Two places, the second winning:

1. **Instrument files:** every `.inst` file in `instruments/`, read at startup and on **F7**,
   so a sound can be changed and heard without a rebuild. The orchestra is split by family
   (`strings.inst`, `woodwinds.inst`, …) plus `field_music.inst` for the fife-and-drum extras.
   `based_on` works across files in any order; a block with an existing key changes just the
   lines it gives, so a later file can tweak an earlier one (`define_instrument violin` /
   `gain 0.4` / `end`). Files starting with `_` are skipped. With no files at all the app
   still runs, on a plain square wave, and says so. `instruments/README.txt` documents every
   line.
2. **Inside a song:** the same `define_instrument` blocks in a `.song`, so the song carries
   its instruments and plays the same on any copy of the app. The **embed** button in the
   instrument panel copies the active layer's instrument into the song.

A track stores an instrument id that points at the registry (1) or at the song's own
definitions (2). Files only ever store the key, so ids can change between runs; F7 replaces
definitions in place, so they don't change within one.

### The orchestra (sounding ranges, MIDI numbers) - as shipped in `instruments/`

**Songs stick to these ranges.** The sheet refuses notes outside them, songs written by
hand or by script keep to them too (move a doubling part by octaves rather than past the
top), and `tools/render` warns about any note that is out of range.

| family | instrument | range | recipe |
|---|---|---|---|
| Strings | Violin | G3–G7 (55–103) | saw, delayed vibrato, quick bow attack |
| | Viola | C3–E6 (48–88) | saw, darker tone |
| | Cello | C2–C6 (36–84); A5 is the usual orchestral limit | saw, darker still, slower attack |
| | Contrabass | E1–G4 (28–67) | 50 % pulse, very dark |
| | Harp | C1–G7 (24–103) | triangle pluck, long ring |
| Woodwinds | Piccolo | D5–C8 (74–108) | triangle + breath |
| | Fife | D5–D7 (74–98) | 25 % pulse + triangle + breath, no vibrato: the fife-and-drum corps |
| | Flute | C4–C7 (60–96) | triangle + breath + vibrato |
| | Oboe | B♭3–G6 (58–91) | 12.5 % pulse, nasal |
| | English Horn | E3–C6 (52–84) | 12.5 % pulse, darker |
| | Clarinet | D3–B♭6 (50–94) | 50 % pulse (odd harmonics — a real clarinet's are too) |
| | Bass Clarinet | D2–F5 (38–77) | 50 % pulse, dark |
| | Bassoon | B♭1–E♭5 (34–75) | 25 % pulse, dark |
| | Contrabassoon | B♭0–F3 (22–53) | 25 % pulse, very dark |
| Brass | French Horn | B♭1–F5 (34–77) | 50 % pulse + triangle, slow swell |
| | Trumpet | E3–C6 (52–84) | 25 % pulse, fast bright attack |
| | Trombone | E2–C5 (40–72) | saw, slight slide-in |
| | Tuba | D1–F4 (26–65) | 50 % pulse, dark |
| Percussion | Timpani | D2–A3 (38–57) | triangle + noise, pitch drop |
| | Glockenspiel | G5–C8 (79–108) | sine + octave, bell decay |
| | Xylophone | F4–C8 (65–108) | triangle, very short |
| | Tubular Bells | C4–F5 (60–77) | sine + inharmonic layer |
| | Snare Drum | row = brightness | noise burst |
| | Field Drum | row = brightness | darker, longer noise + low triangle: the colonial rope drum |
| | Bass Drum | row = weight | triangle, big pitch drop |
| | Cymbals | row = brightness | metallic ("short") noise |
| Keyboards | Piano | A0–C8 (21–108) | 25 % pulse, struck decay |
| | Harpsichord | F1–F6 (29–89) | 12.5 % pulse, fast pluck |
| | Celesta | C4–C8 (60–108) | sine + octave, soft pluck |
| | Organ | C1–C7 (24–96) | 50 % pulse + octave, no envelope |
| Voices | Choir | E2–A5 (40–81) | 50 % pulse, slow attack, wide vibrato |
| Chip | Pulse Lead | C2–C7 | 25 % pulse — the NES lead |
| | Square Lead | C2–C7 | 50 % pulse |
| | Triangle Bass | A0–C5 | the NES bass |

Ranges are *sounding* pitch (what you hear), not the written pitch of transposing
instruments — the sheet shows what plays.

## 3. The sheet

### 3.1 Vertical: staff rows

One row per **line or space** (a diatonic step), not per semitone — it reads like sheet
music and the rows are twice as tall to click. 88 piano keys are 52 steps (A0 … C8),
at 12 canvas pixels a row.

* Steps are numbered from C0 = 0, so C4 (middle C) = 28. Octave = step / 7,
  letter = step % 7.
* **Every even step is a line.** Treble is E4 G4 B4 D5 F5 = steps 30–38, bass is
  G2 B2 D3 F3 A3 = 18–26, and middle C (28) is the ledger line between them — so
  "lines on every even step" is exactly one continuous staff with both clefs (and the
  alto clef's C4 centre line) in it. Treble and bass lines are drawn bold; the rest faint.
* **Sharps and flats** are a modifier on the row. The song's **key signature** decides the
  default (in D major, a click on an F row makes F♯). Hold **Shift** for ♯, **Ctrl** for ♭,
  or set the accidental mode in the panel; the **mouse wheel** over a note nudges it a
  semitone; ↑/↓ move a selected note by step, Shift+↑/↓ by semitone. Accidentals are
  drawn only where they differ from the key, as on paper.

### 3.2 Horizontal: ticks and snapping

A quarter note is **24 ticks**. That one number holds every length we want:

| length | ticks | | triplet | ticks |
|---|---|---|---|---|
| whole | 96 | | whole-triplet | 64 |
| half | 48 | | half-triplet | 32 |
| quarter | 24 | | quarter-triplet | 16 |
| eighth | 12 | | eighth-triplet | 8 |
| 16th | 6 | | 16th-triplet | 4 |
| 32nd | 3 | | 32nd-triplet | 2 |

Dotted lengths are ×1.5 (a dotted 32nd would be 4.5 ticks, so there isn't one).

A 4/4 bar is 96 ticks; 3/4 and 6/8 are 72. A note **snaps to slots of its own length**,
counted from the start of its bar — a quarter note has 4 slots in 4/4, an eighth-triplet
has 12. A dotted note snaps to half its length (a dotted quarter lands on eighths), which
is where dotted notes actually fall in real music. Alt while placing snaps to 32nds.

### 3.3 Layout (1280 × 720 canvas)

```
┌──────────────────────── top bar: title · tempo · time · key · transport · file ────────────────────────┐
│ layers      │ gutter │   bar 1         │   bar 2         │   bar 3         │   bar 4         │
│  ▣ Violin   │  C8    │                                                                         │
│  ▣ Cello    │  ...   │   continuous super-staff, 52 rows × 12 px                               │
│ + instrument│  C4 ── │                                                                         │
│ length      │  ...   │                                                                         │
│ accidental  │  A0    │                                                                         │
│             │        ├───────────── page strip: every page as a box, click to jump ────────────┤
└──────────────────────── status bar: hovered pitch, frequency, position, hints ─────────────────────────┘
```

The canvas is drawn at 1280 × 720 and scaled to the window — 1:1 at 720p, a sharp 2×
at 1440p, and the two-step "sharp" upscale in between (1.5× at 1080p). That is the
virtual-resolution code from Animal Kingdoms (`source/rlu`), with the canvas raised from
960 × 540. The default raylib font is a pixel font, which suits it.

**Key lines** (the "lines" toggle, on by default). The sheet has a row per letter, so every
row is already in the key: a click on an F row in G major places F♯. What the toggle shows
instead is what is easy to lose track of: the rows the signature changes (sharp rows tinted
warm, flat rows cool, named F♯ / B♭ in the gutter) and the rows of the key's home chord
(the major triad on the tonic: tonic brightest, 3rd and 5th fainter). A minor key shares
its signature with the relative major, whose chord is the one marked.

With key lines on, the gutter also shows each row's **frequency ratio** to a reference note,
as the whole-number ratio the interval is heard as (5-limit just intonation: octave 2:1,
fifth 3:2, fourth 4:3, major third 5:4, major sixth 5:3, second 9:8, seventh 15:8, and
their octaves - with C5 as 1:1, C6 is 2:1, G4 3:4, C4 1:2). The reference is the key's
tonic at or just below the first note of the layer being edited; right-click a row name to
pick another, again to go back to automatic. Rows more than three octaves away show none.
The gutter is 72 px wide to hold them.

### 3.4 Layers

A layer is a **track**: an instrument, its notes, volume, pan, mute and solo. Normally
one per instrument; add a second Violin layer for Violin II. The active layer is drawn
on top at full strength; the others at ~35 %, so you can see the chords you are writing
against. MIDI import creates one layer per MIDI track+channel.

### 3.5 Play mode

`Space` plays from the start of the current page (`Shift+Space` from the beginning).
The playhead sweeps across, every sounding note is outlined and brightened in every
layer, and with **Follow** on the view flips to the next page as the playhead leaves this
one. Mute and solo apply live to the next play.

## 4. Code layout

Same shape as Animal Kingdoms, trimmed to what a tool needs:

| path | |
|---|---|
| `main_hot_reload/` | the hot-reload host, unchanged apart from names: owns the window, swaps `build/hot_reload/game.dll` |
| `main_release/` | shipping entry point |
| `source/` | package `app` — one package, one file per concern. All state in one `App` block (`g`) so hot reload keeps the song you are editing |
| `source/mode.odin` | music box or Cello Helper: `-define:CELLO=true` (§4.3) |
| `source/rlu/` | virtual resolution, vendored from Animal Kingdoms (canvas 1280 × 720) |
| `source/music/` | package `music` — **no raylib**. Theory (pitches, keys, lengths), the song model, the `.song` format, the instrument table, the synth engine, sound effects, the Mixer, WAV writing and MIDI import. Headless, so `tools/render` can use it, and so can any other program (§4.2) |
| `source/music_rl/` | package `music_rl`: the Mixer's sound out through a raylib `AudioStream`. The only raylib-facing piece of the engine |
| `tools/render/` | CLI: render a `.song` or `.mid` straight to WAV, or sound effects (`-- sfx cannon`, `-- sfx all`) |
| `examples/battle_demo/` | the engine inside another program: a march with layers toggled live, battle sounds on keys |
| `instruments/` | the orchestra, `.inst` files |
| `sounds/` | sound effects, `.sfx` files |
| `songs/` | saved songs |
| `imports/` | drop `.mid` files here (or drag them onto the window) |
| `exports/` | rendered WAV / MP3 / OGG / FLAC |

### 4.1 The synth

`sounds_example.odin` builds every sound as maths on a sample buffer. The synth keeps
that idea — tones, noise, fades, a one-pole "muffle" — but turns it from "render a
whole sound up front" into a **block engine** so playback starts instantly:

1. `engine_start` flattens the song (honouring mute/solo) into note events sorted by
   start time.
2. `engine_render(out)` fills one block: starts any voice due in the block, renders every
   live voice into it, retires finished ones.
3. Live playback feeds blocks to a raylib `AudioStream` from the main loop (no audio
   callback, so a hot reload never swaps code out from under the audio thread).
   Export runs the same engine to the end into one buffer, normalises, writes WAV.

**Live mix.** Every track's notes go into the engine, muted or not, and each track
has a gain (0–1) applied as it plays. Mute, solo and volume changes are heard within one
block (~46 ms), faded rather than cut; the editor simply calls `engine_sync_mix` every
frame. A muted note keeps time without being synthesised, so unmuting mid-note brings the
rest of it in. Breath noise is per voice, seeded from the note, so muting one track never
changes how another sounds.

**Playing songs from another program**: see §4.2, the Mixer.

Pulse and saw are band-limited with PolyBLEP so high notes do not alias into a screech;
the triangle is deliberately left as the NES's 16-step staircase. Pitch modulation
(vibrato, sweep) is computed at control rate (every 32 samples).

### 4.2 The engine for other programs: the Mixer

The editor is one user of the engine; a game is another. Everything a program needs is one
struct, `music.Mixer` (`source/music/mixer.odin`), and the editor itself plays through it,
so what the editor does is what a game gets.

```odin
import music "music"          // copy source/music into your project
import music_rl "music_rl"    // and source/music_rl, for raylib output

m: music.Mixer
music.mixer_init(&m)
music.mixer_load_instruments(&m, "instruments")   // the .inst files
music.mixer_load_sounds(&m, "sounds")             // the .sfx files

out: music_rl.Output
music_rl.output_open(&out)                        // after rl.InitAudioDevice()

march := music.mixer_play_song_file(&m, "songs/british_grenadiers_trumpet.song", loop = true, fade_in = 2)
music.mixer_set_layer(&m, march, "Trumpet 1", false)     // one layer, by its name
music.mixer_set_instrument(&m, march, "trumpet", false)  // every layer playing the trumpet
music.mixer_solo_layer(&m, march, "Trumpet 2")           // only this layer
music.mixer_set_all_layers(&m, march, true)              // everything back
music.mixer_play_sfx(&m, "cannon", pan = -0.4, vary = 1)
music.mixer_stop_song(&m, march, fade_out = 3)

// every frame:
music_rl.output_update(&out, &m)
```

| | |
|---|---|
| **Songs** | `mixer_play_song_file` / `mixer_play_song` (a `Song` already in memory) → a `Song_Handle`. Up to 4 at once (the music, a fanfare over it). Loop, fade in, `mixer_stop_song` with a fade out, `mixer_set_song_volume` over time, `mixer_song_playing`, `mixer_song_time` |
| **Layers** | by layer name ("Trumpet 1"): `mixer_set_layer`, `mixer_set_layer_gain`, `mixer_solo_layer`, `mixer_layer_on`. By instrument key, reaching every layer that plays it ("trumpet"): `mixer_set_instrument`, `mixer_set_instrument_gain`, `mixer_solo_instrument`, `mixer_instrument_on`. `mixer_set_all_layers` for everything. Names ignore case; setters return how many layers they changed. `mixer_layer_count` / `mixer_layer_name` list them for a menu |
| **Bursts** | `mixer_play_sfx_burst(key, count, seconds, volume, pan_spread, vary)`: many of one effect, start times drawn from a normal distribution (σ = seconds/6, redrawn if outside), each shot with its own pitch, loudness and pan; the group scaled by 1/√(shots in the busiest 50 ms) so it does not clip. One handle for all. The editor's SFX tester uses it |
| **Sound effects** | `mixer_play_sfx(key, volume, pan, pitch, vary)` → a `Sfx_Handle`; `vary` shifts each shot by a random amount so ten muskets are not one musket ten times; `mixer_stop_sfx`. `mixer_play_note(inst_key, midi)` plays a single orchestra note (a UI blip, a stinger) |
| **Levels** | `master`, `music_volume`, `sfx_volume`: plain fields, the options-menu sliders |
| **Output** | `mixer_render(&m, block)` fills any block of stereo f32 at 44.1 kHz. `music_rl` does it for raylib; any other audio API works the same way |

Rules that keep it simple: handles are safe after their sound has ended (calls on them do
nothing); every change ramps over one block, so nothing clicks; not thread-safe, so feed
the output from the game loop (as `music_rl` does) rather than an audio callback, or guard
it with a mutex; one mixer per program (songs find instruments through the package's bound
registry — `mixer_bind` after a hot reload).

Loop length is the song rounded up to a whole bar, so the beat carries across the seam, and
notes ringing at the end ring on into the next pass.

**Sound effects** are text too: `.sfx` files in `sounds/` hold `define_sfx` blocks, each a
handful of voices (instrument, pitch, start, length, volume, pan), and can define
instruments of their own that stay out of the editor's list (see `sounds/README.txt`).
`sounds/battle.sfx` has a cannon (a falling triangle thump, dark noise, a bright crack and a
long rumble), a distant cannon, a musket and a ragged volley, a sword clash (inharmonic
sine partials over metallic noise), a sword being drawn, a ship's bell and a splash.

### 4.3 The Cello Helper

A second program, `cello_helper.exe`, built from the same `source/` package with
`-define:CELLO=true` (`source/mode.odin`). Everything is shared — the sheet, layers, undo,
files, the Mixer — and `when CELLO` switches the differences:

* **Only the cello.** "+ Add cello layer" instead of the instrument picker; a song opened
  here has every layer turned into a cello ("Cello (was Violin)"), out-of-range notes
  shown red and counted. Saves go to `cello_songs/`, so an orchestral song in `songs/`
  is never overwritten by its cello version.
* **Only the cello's rows, by default:** the range button (in both apps: "piano" / "inst",
  `g.fit_range`, `sheet_range_update`) shows either the piano's 52 rows of 12 px or only
  the active instrument's compass, the rows as tall as fit (up to 36 px) with bigger note
  heads - C2 to C6 in 29 rows of 21 px for the cello. The music box starts on piano, the
  Cello Helper on inst. Notes outside the instrument's range are drawn red (piano range)
  or counted at the sheet's top and bottom edge (inst range); they cannot be added, but can
  be deleted, dragged into range, or octave-copied into range.
* **Four bars to a page**, as in the music box: the left panel is half as wide (104 px,
  laid out compact - stacked rows, short labels) and the sheet runs to the fingerboard
  (748 px).
* **The Cello Fingerboard** (`source/fingerboard.odin`), a 348 px panel down the right:
  just the board (drawn three quarters of its first width), the note names beside it,
  the 8va marks to its left, the finger labels at the edge, and the key and hand-position
  buttons above.
  Player's view: nut at the top, strings C G D A left to right, 29 semitones per string
  to the end of the fingerboard. Semitone *n* sits at `1 - 2^(-n/12)` of the string, so
  positions crowd together down the board as they do under the hand; the octave (half
  the string) and two octaves (three quarters) are marked. Lit: the note under the mouse
  on the sheet — at every place it can be played — the active layer's sounding notes
  while playing, the selected note, and the circle under the mouse here (its row is lit
  on the sheet too). Click to hear. The key filter (All, 15 keys, Song) hides positions
  whose note is not in the key's major scale (= its relative minor); lit notes always
  show. Positions above the cello's range (C6) are drawn as empty rings.
* **Hand positions.** Lines across the board where each finger stops the strings in the
  chosen position, labelled f1–f4 (and T for the thumb) at the right-hand edge of the
  screen; buttons pick the position (default 1st), the mouse wheel over the board steps
  through them. Semitones above the open string, the same on every string
  (`HAND_POSITIONS` in `fingerboard.odin`): half 1-2-3-4, 1st 2-3-4-5, 1st extended
  2-4-5-6, lower 2nd 3-6, 2nd 4-7, 3rd 5-8, upper 3rd 6-9, 4th 7-10 (closed hand, a
  semitone between fingers, so 1 to 4 spans a minor third); 5th, a three-finger position,
  9-10-12 (F♯ G A on the A string); 1st thumb position, thumb on the octave (12) and
  1-2-3 on 14-16-17 (B C♯ D). 6th and 7th are left out until checked against a method
  book: sources disagree on where they sit.

**Tracking** (`source/fingering.odin`). Every note of the active layer is given a place on
the board (a string and a semitone), in order from the start of the layer, each from the
last: *Same string* keeps the string while it can play the note and otherwise takes the
nearest place; *Nearest* always takes the physically nearest; the first note goes lowest
on the neck. Physical distance uses a full-size cello: strings 695 mm nut to bridge, 23 mm
outer to outer at the nut and 47 mm at the bridge (Hans Johannsson's cello measurements),
semitone *n* at 695·(1 − 2^(−n/12)) mm from the nut; the distances between all 120 places
are worked out once into a table. The last N notes up to the playhead (or the selected
note) are drawn: each note filled in a colour cycled note by note (eight colours; older
notes fainter, the newest ringed), and between them either the string and its circles
coloured in, blending from one colour to the next, or a blended arrow straight across.
*Best* (a third mode, and the default) always takes the place nearest the nut - the open string if there is
one ([C string, F2] → G2 is the open G string). **Steps:** notes that start within 6 ticks
of each other while the first still sounds (double stops, chords, strums) are one step;
their places are chosen together, on different strings, at the least total cost (every
assignment tried, at most 4^4); the colour and the N count go by step. Each note gets one
line in: voice by voice (lowest to lowest) between chords of the same size, otherwise from
the nearest note of the step before. Places past the thumb position's reach are used only
when a note has no other.

**The board's length follows the hand position:** it shows from the nut to three semitones
past the last finger (at least 7, at most 20 - the thumb position's reach), gliding to a
new length when the position changes; notes are spaced over what is shown, so they get
bigger in the low positions. A tracked note past what is shown is pinned to the board's
end and named.

With tracking on, the notes playing light only at the place chosen for them; the layer's
own colour is no longer used on the board. On the sheet, the active layer's notes in the
trail are drawn in their tracking colour blended with the layer's: the k-th of n (oldest
first) at weight (k+1)/n, so the newest shows the full colour and each fades back a step
per note - the same steps as their fading on the board.

Its own hot-reload library (`build/hot_reload/cello.dll`, the host built with
`-define:GAME_NAME=cello`) and its own `last_cello_song.txt`, so it can run beside the
music box.

### 4.4 Performance

**F3** opens a monitor (`source/perf.odin`); the FPS is always shown top right. Each
frame is timed in four parts - logic, audio mixing, drawing, present (which includes the
wait for the display, so it is idle time) - averaged and worst-cased over two seconds and
graphed over the last 240 frames, with the mixing load (% of real time), voice counts and
stream underruns.

What it found first (80 muskets over 3 s): the mixing, and within it two things.
`math.floor` - used to wrap oscillator phases - is a software routine in Odin, and was
half the synth's time in a debug build; a truncating conversion does the same for the
non-negative phases, bit for bit. Struck notes (drums, gunfire) computed `exp()` every
sample for their decay; it is now one multiply a sample. Bounds checks are off in the
voice loop. Together about 3x less work (a debug-build block at the peak of the burst:
63 ms → 19 ms; release: 11 ms → 4 ms). And the mixing is now spread over the frames
(`music_rl.output_update`: 128-frame pieces, a little more than a frame's worth each,
kept a block ahead) instead of a whole block at once every few frames, and the editor's
block is 1024 frames (23 ms) - about 70 ms of sound buffered in all.

The hot-reload build is a debug build (`-debug`, no optimisation) and mixes several times
slower than a release build; adding `-o:speed` to `build_hot_reload` trades stepping in a
debugger for speed.

## 5. The `.song` format

Plain text, one statement per line, `#` comments. Readable, diffable, hand-editable —
the same spirit as the Animal Kingdoms definition files.

```
# 8-Bit Music Box song
format 1
title "Ode to Joy"
tempo 112            # quarter notes per minute
time 4/4
key 2                # sharps (+) or flats (-): 2 = D major / B minor
bars 16

track "Violin"
instrument violin     # key from the instrument table
volume 0.8
pan -0.3
mute 0
solo 0
color 80 170 246     # optional: the layer's own colour on the sheet (Set colour)
# note  tick  length  pitch  velocity      (24 ticks = one quarter note)
note 0 24 F#4 100
note 24 24 F#4 100
end
```

* Pitch is spelled (`F#4`, `Bb3`, `E4`) so the sharp/flat choice survives a round trip.
* Unknown statements are warned about and skipped, so newer files open in older builds.
* `format` is bumped on any breaking change; the loader refuses a newer major version with
  a message rather than guessing.

## 6. Export

| format | how |
|---|---|
| WAV | built in: 16-bit PCM, stereo, 44.1 kHz |
| MP3 / OGG / FLAC | render WAV, then `ffmpeg -y -i song.wav song.mp3`. Buttons appear only when `ffmpeg` is on PATH |

Encoding MP3 in-process would mean vendoring LAME or shine; not worth it while ffmpeg exists.
raylib can *decode* MP3/OGG/FLAC/WAV itself (`rl.LoadWave`), which is what audio import will use.

## 7. MIDI import (in v0)

Standard MIDI File, format 0 or 1.

* Ticks are rescaled from the file's division to 24 per quarter and snapped to the nearer of
  the 32nd grid (3 ticks) and the triplet grid (4 ticks).
* One layer per (MIDI track, channel). The General MIDI program picks the instrument
  (40 → Violin, 42 → Cello, 73 → Flute, 56 → Trumpet, …); channel 10 becomes Snare / Bass
  Drum / Cymbals layers.
* Notes outside the chosen instrument's range are moved by octaves until they fit, and the
  import reports how many.
* First tempo, time signature and key signature are used (MB-2).

## 8. Audio import (later)

Honest expectation: turning a mixed orchestral recording into exact notes is an unsolved
research problem. What is realistic, in order of effort:

1. **Monophonic** (one melody line, e.g. a solo): YIN/pYIN pitch tracking + onset
   detection → very usable.
2. **Polyphonic draft**: constant-Q spectrogram → peak-pick per 16th-note slice → notes,
   tempo from onset autocorrelation. Gives a sketch to fix by hand on the sheet; the sheet
   is exactly the tool for that clean-up.
3. **ML transcription** (e.g. Spotify's Basic Pitch) run *outside* the app, producing a
   `.mid` that the MIDI importer takes. Best quality, zero code in the app.

Recommendation: option 3 now, option 2 in-app later if it is still wanted.

## 9. How to Dosbox capture (research, high value)

The game's music is not in the MP3s as notes, but it is in the game as a **score**:
`ASOUND.COL`, `GSOUND.COL`, `PSOUND.COL` and `RSOUND.COL` in `MPS/COLONIZE` look like
per-device sound banks (AdLib / General MIDI / PC speaker(?) / Roland). The easiest way to
get exact notes without reverse-engineering them:

1. In the DOSBox config, set `mididevice` so DOSBox has a MIDI out, and pick **General MIDI**
   or **Roland** as the game's music device.
2. In game, press **Ctrl+Alt+F8** — DOSBox starts recording raw MIDI to its `capture`
   folder as `.mid`. Press again to stop.
3. Drop the `.mid` into `imports/` — every tune comes in with its real notes, rhythms and
   instrument choices.

This beats any audio transcription and should be tried first.

**But a capture is the game's arrangement, which is copyrighted even where the tune under it
is not.** Captures go in `songs_that_cannot_be_used_for_legal_reasons/`, for study. What we
publish is our own arrangement of the public-domain tune from a period source. Which tunes
those are, and where to get them, is in `.design/COLONIZATION_MUSIC.md`.

## 10. Milestones

| # | what | state |
|---|---|---|
| v0 | window + scaling, sheet with 4-bar pages, all instrument layers with real ranges, note placing / moving / deleting, accidentals and key signature, undo, chip synth, play mode with highlight and page-follow, `.song` save/load, WAV export, ffmpeg export, MIDI import, drag-and-drop | **this build** |
| v1 | velocity lane (MB-4), copy/paste of bar ranges, loop a page range, per-layer instrument editing (duty, envelope) saved in the song | |
| v2 | tempo map (MB-2), ties (MB-3), chip-strict voice limit (MB-1) | |
| — | instrument files (`instruments/*.inst`, F7 reload) and song-embedded instruments | **done** |
| — | the Mixer: an engine for other programs (songs, live layer muting, looping, fades, sound effects in `sounds/*.sfx`) | **done** |
| v3 | audio → notes draft transcription (§8) | |
