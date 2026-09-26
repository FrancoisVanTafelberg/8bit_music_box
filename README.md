# Bob's 8-Bit Music Box

A sheet-music editor with a chiptune orchestra, in Odin and raylib. Draw notes onto a
4-bar page that holds the whole piano range at once, one instrument layer at a time,
and hear it played back as 8-bit strings, woodwinds, brass and percussion.

The design, the reasoning, and what comes next are in **`.design/DESIGN.md`**.

## Build

Needs **Odin `dev-2026-06` or newer** on PATH. raylib comes with Odin.

    build_hot_reload.bat          (or ./build_hot_reload.sh)
    build\8bit_music_box_dev.exe  run from this folder, so songs\ is found

    run_dev.bat                   builds, then starts it

Leave it running and re-run the build script: the code is swapped in place and the song
you are editing survives. `F5` forces a reload, `F6` restarts.

    build_release.bat             (or ./build_release.sh)
    build\8bit_music_box.exe

## The Helper (fingerboards)

**Helper** in the top bar (or `H`): a practice view for string players. The layer panel
narrows, the sheet shows only the selected layer's instrument's rows (the **inst** range;
turning the Helper off puts back what was there), and the right-hand side shows that
instrument's **fingerboard** - or, for the **piano**, **harpsichord**, **celesta** and
**organ**, its **keyboard**. Select another layer and it changes with it. Boards come from
the instrument files: the **violin**, **viola**, **cello**, **contrabass** and **guitar**
have a fingerboard, the keyboard instruments a keyboard; for any other instrument the
panel says the fingerboard is not implemented for it yet. (This replaces the separate
Cello Helper program.)

The keyboard is turned on its side and lined up with the sheet: every white key lies
right beside its row (the rows are the white keys, a letter each) and every black key on
the line between its two, low notes at the bottom, the black keys toward the sheet. Point
at a note on the sheet and its key lights; point at a key and its row lights; click a key
to hear it; the sounding notes light while playing. Beside it: the key filter (keys outside
the chosen key go grey), **Tracking** (the last N notes up to the playhead or the selected
note, each key filled in its step's colour with the hand's path drawn from key to key, and
the same colours on the sheet), what the pointed-at note is, and in input mode the note
the mic hears - also a dot on its key, off-centre by how sharp or flat it is.

The fingerboard is the player's view down the neck: nut at the top, lowest string on the
left, every place a finger can stop a string from the open string to the end of the
board, spaced as they really are (closer together further down). On the guitar the frets
and the inlay dots are drawn, and each note sits between its fret and the one before,
where the finger goes. Point at a note on the sheet and every place it can be played
lights up; while playing, the current layer's sounding notes light up; click a circle to
hear it. The key buttons show only the notes of that key (**All** shows every position,
**Song** picks the song's key). The position buttons (or the mouse wheel over the board)
choose a hand position - the instrument's own: semitone-apart fingers on the cello, the
violin and viola's frame, Simandl on the double bass, a finger per fret on the guitar -
and draw a line across the board for each finger, labelled f1–f4 at the right edge.

**Tracking** (on by default) follows the layer note by note: the last N notes (8 by
default; Shift/Ctrl for 10/100 on the -/+) up to the playhead - or up to the selected note
when stopped - each filled in its own colour, with the way between them drawn: along the
string, as a line straight down it blending from one note's colour to the next, or as an arrow straight across the board to another string. Three
modes: **Same string** stays on the string while it can play the note; **Nearest** goes to
whichever place is physically closest on the real instrument (its string length and
spacing are in its instrument file); **Best** (the default) always takes the place nearest
the nut (the open string when there is one). Notes played together - double stops,
chords, strums (starting within 6 ticks, while the first still sounds) - go on different
strings and each gets its own line: voice by voice from a chord of the same size, otherwise
from the nearest note before. A guitar chord of six notes takes all six strings.

The **Fixed** / **Dynamic** button next to the mode sets the board's length. **Fixed** (the
default) always shows it down to the instrument's reach (a cello's thumb position, the
guitar's last fret). **Dynamic** shows only as much as the hand position needs - from the
nut to a little past the last finger - so 1st position fills the panel with big notes, and
changing position glides to the new length. On the sheet, the same notes take the same
colours - the newest fully - and fade back to the layer's colour a step per note, at the
rate they fade on the board.

Songs the old Cello Helper saved in `cello_songs\` still show in Open, marked [cello].

## Using it

| | |
|---|---|
| **Place a note** | pick a length on the left (`1`–`6`, `.` dotted, `T` triplet), click a slot |
| **Sharps / flats** | the key signature decides; hold `Shift` for ♯, `Ctrl` for ♭, or use the accidental buttons |
| **Edit** | drag to move, right-click to delete, mouse wheel on a note = up/down a semitone |
| **Range** | the **piano** / **inst** button next to the key: the whole piano range, or only the selected layer's instrument (taller rows). Starts on piano; the Helper switches to inst while it is on. Notes outside the range are red on the piano range and counted at the sheet's edge on inst - switch to piano to move or delete them |
| **Key lines** | the **lines** button next to the key: rows the key signature sharpens or flattens are tinted and named (F#, Bb) in the note column, and the rows of the key's home chord are marked - tonic brightest, 3rd and 5th fainter. Each row also shows its frequency ratio to a reference note (the tonic at or below the layer's first note): with C5 as 1:1, C6 is 2:1, G5 3:2, E5 5:4, C4 1:2. Right-click a row's name to make it the reference; right-click it again for automatic. On by default |
| **Sound effects** | the **SFX** button (top right): every sound effect in `sounds/`, click to hear; "many at once" fires N of one over a few seconds (the -/+ take Shift for 10 and Ctrl for 100 at a time, the wheel works too, right-click resets), bunched on a bell curve (e.g. 100 muskets in 2 s), with a chart of when each fell |
| **Octave copy** | `Ctrl`+click a note: a copy of it an octave lower, same place and length; `Shift`+click: an octave higher |
| **Selected note** | `Alt+↑/↓` a staff step, `Alt+Shift+↑/↓` a semitone, `Alt+←/→` a slot, `Del` removes it |
| **Bars** | `←` back to the start of the bar (at its start already: the bar before), `→` the start of the next bar - while playing it jumps there; stopped, it moves the bar cursor (the gold marker) that Play starts from |
| **Volume** | `↑` / `↓` the overall volume, 5% a press (`Shift`: 20%) |
| **Fine grid** | hold `Alt` to snap to 32nds |
| **Helper** | `H` or the **Helper** button: the selected string layer's fingerboard on the right (see above) |
| **Layers** | `+ Add instrument`; click a layer to edit it; `M` mute, `S` solo (live, even mid-song); `Tab` next layer; **Set colour** picks the selected layer's colour on the sheet (saved in the song) |
| **Play** | `Space` from the bar cursor (or this page's start, if the cursor is on another page), `Shift+Space` from the start. **Follow** turns pages with the playhead |
| **Play scope** | the **Song / Bar / Page** button under the sheet (right of the page boxes): the whole song, one bar from the cursor, or to the end of the page. Bar and Page stop at their end (a red line marks it) and leave the cursor where it was, so Play goes round the same bar again; `→` moves on. Right-click steps back |
| **Metronome** | the top layer is always the **Metronome**. **Metro** under the sheet (or `K`, or its `on` button) fills every bar with a click a beat, the first beat of each bar higher; they follow the time signature and the number of bars, and go again when it is switched off. It plays in time with the song, keeps going when another layer is soloed, has its own `M` mute, and is never saved or exported. Its clicks show as ticks along the top of the sheet |
| **Input mode** | **Mic** under the sheet (or `I`) listens to a microphone and shows the note you play: a big dot on the sheet, in the colour opposite the layer's, on that note's row - above or below the row's middle when sharp or flat, with the name and cents beside it (green in tune, gold within 25 cents, red beyond). Stopped, it sits on the bar cursor; playing, it rides the playhead and leaves a line behind it - the take - which stays until Play or **Reset**. With the Helper on it also shows where the note is on the fingerboard. Listens for the selected layer's range. Windows only for now |
| **Microphone** | the **v** button beside Mic: pick any input device (or the system default), watch the level (the white mark is the noise gate), set **ignore noise** (how far above the room's own noise a note must be: x2 / 6 dB by default; raise it in a noisy room) and **latency** (raise it if the take lags the notes). The room's noise is learned by itself while you are not playing. Use headphones when playing along - the mic hears the speakers too |
| **Pages** | `PgUp`/`PgDn`, `[` `]`, or click the page strip |
| **Undo** | `Ctrl+Z`, `Ctrl+Y` / `Ctrl+Shift+Z` |
| **Files** | `Ctrl+S` save, `Ctrl+O` open, `Ctrl+N` new, `Ctrl+E` export WAV |
| **Import** | put `.mid` files in `imports\` and Open them, or drag a `.mid` / `.song` onto the window |
| **Export** | WAV built in; MP3 / OGG / FLAC light up when `ffmpeg` is on PATH |
| **Sound mode** | the 8-bit button: click cycles **4-bit** (NES 16-step volume, grittiest), **8-bit** (default), **16-bit** (a player's touch: tuning, vibrato and bow scratch vary note to note), **32-bit** (modelled bowed strings and wooden bodies); right-click goes back. Export uses it too |
| `F3` | performance monitor: where each frame's time goes (logic, audio mixing, drawing, present), the mixing load, voices, underruns, and a graph of the last 240 frames. The FPS is always shown top right (click it too) |
| `F7` | reload the instrument and sound effect files |
| `F11` | fullscreen |

Rows the active instrument cannot play are shaded and refuse clicks.

## Folders

| | |
|---|---|
| `source/` | package `app`: the editor. All state in one block for hot reload |
| `source/music/` | package `music`, no raylib: theory, song model, `.song` format, instruments, synth, sound effects, the Mixer, WAV, MIDI import |
| `source/music_rl/` | the Mixer's sound out through raylib |
| `source/rlu/` | virtual resolution (1280 × 720 canvas), from Animal Kingdoms |
| `tools/render/` | `odin run tools/render -- songs/ode_to_joy.song` renders to WAV with no window (`-4` `-8` `-16` `-32` pick the sound mode); `-- sfx all` renders every sound effect |
| `examples/battle_demo/` | the engine in another program: `odin run examples/battle_demo` |
| `instruments/` | every instrument, as text files (`.inst`): add or change them without a rebuild, F7 reloads. See `instruments/README.txt` |
| `sounds/` | sound effects that are not music (cannon, musket, sword clash...), as text files (`.sfx`). See `sounds/README.txt` |
| `songs/` | saved songs (plain text, hand-editable) |
| `cello_songs/` | songs the old Cello Helper saved (still listed in Open) |
| `imports/` | MIDI files to open |
| `exports/` | rendered audio |
| `songs_that_cannot_be_used_for_legal_reasons/` | songs and MIDI of music that is **not** public domain: playable here, never copied to the repo or committed |

## Using the engine in another program

`source/music` (no raylib) plays songs, mutes and unmutes their layers by name while they
play, loops and fades them, and plays sound effects on top; `source/music_rl` sends it to
the speakers in a raylib program. Copy those two folders, plus `instruments/`, `sounds/`
and your songs:

    m: music.Mixer
    music.mixer_init(&m)
    music.mixer_load_instruments(&m, "instruments")
    music.mixer_load_sounds(&m, "sounds")
    out: music_rl.Output
    music_rl.output_open(&out)                   // after rl.InitAudioDevice()

    march := music.mixer_play_song_file(&m, "songs/british_grenadiers_trumpet.song", fade_in = 2)
    music.mixer_set_layer(&m, march, "Trumpet 1", false)      // one layer, by its name
    music.mixer_set_instrument(&m, march, "trumpet", false)   // every layer playing it
    music.mixer_play_sfx(&m, "cannon")

    music_rl.output_update(&out, &m)             // every frame

The whole API is at the top of `source/music/mixer.odin` and in `.design/DESIGN.md` §4.2;
`examples/battle_demo` is a working program.

## Copying to the GitHub repo

`E:\.workspace\8bit_music_box` is the git repository that talks to GitHub; this
folder is where the work happens. To bring the repo up to date:

    copy_to_repo.bat -DryRun      say what would happen, change nothing
    copy_to_repo.bat              back up, clear, copy (asks first)
    copy_to_repo.bat -Force -Prune 5

It backs the repo folder up to `8bit_music_box.bak.YYYY-MM-DD-HH-MM` first, keeps its
`.git` and `.gitignore`, and does not copy `.temp`, `build`, `exports`,
`last_song.txt`, `last_cello_song.txt` or `songs_that_cannot_be_used_for_legal_reasons`. Nothing is written back here.

## Files marked for deletion

Claude can write files in this folder but not remove them, so a file that should go
gets a companion `<file>.delete` saying why. Run

    tools\clean_marked.bat       (or ./tools/clean_marked.sh)

to delete every marked file and its marker - before `copy_to_repo`, so they do not
travel to the repo. The same convention as Animal Kingdoms.
