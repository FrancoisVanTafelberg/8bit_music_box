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
* **4-bit volume** — NES channels had 16 volume levels, so fades are staircases. The synth
  quantises every envelope to 16 steps by default ("crush"), which is a lot of the
  authentic grit.

That is exactly what `source/music/instruments.odin` records per instrument. The whole
orchestra is built from five oscillators: pulse, triangle, saw, sine, noise.

### The orchestra (sounding ranges, MIDI numbers)

| family | instrument | range | recipe |
|---|---|---|---|
| Strings | Violin | G3–G7 (55–103) | saw, delayed vibrato, quick bow attack |
| | Viola | C3–E6 (48–88) | saw, darker tone |
| | Cello | C2–A5 (36–81) | saw, darker still, slower attack |
| | Contrabass | E1–G4 (28–67) | 50 % pulse, very dark |
| | Harp | C1–G7 (24–103) | triangle pluck, long ring |
| Woodwinds | Piccolo | D5–C8 (74–108) | triangle + breath |
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
| `source/rlu/` | virtual resolution, vendored from Animal Kingdoms (canvas 1280 × 720) |
| `source/music/` | package `music` — **no raylib**. Theory (pitches, keys, lengths), the song model, the `.song` format, the instrument table, the synth engine, WAV writing and MIDI import. Headless, so `tools/render` can use it |
| `tools/render/` | CLI: render a `.song` or `.mid` straight to WAV. `odin run tools/render -- songs/ode_to_joy.song` |
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

Pulse and saw are band-limited with PolyBLEP so high notes do not alias into a screech;
the triangle is deliberately left as the NES's 16-step staircase. Pitch modulation
(vibrato, sweep) is computed at control rate (every 32 samples).

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

## 9. Capturing music from DosBox (research, high value)

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

## 10. Milestones

| # | what | state |
|---|---|---|
| v0 | window + scaling, sheet with 4-bar pages, all instrument layers with real ranges, note placing / moving / deleting, accidentals and key signature, undo, chip synth, play mode with highlight and page-follow, `.song` save/load, WAV export, ffmpeg export, MIDI import, drag-and-drop | **this build** |
| v1 | velocity lane (MB-4), copy/paste of bar ranges, loop a page range, per-layer instrument editing (duty, envelope) saved in the song | |
| v2 | tempo map (MB-2), ties (MB-3), chip-strict voice limit (MB-1), song-embedded custom instruments | |
| v3 | audio → notes draft transcription (§8) | |
