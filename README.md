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

## Cello Helper

A second program from the same code: the editor with only the cello (as many cello
layers as you like), two bars to a page, and the **Cello Fingerboard** where the other
two bars were.

    run_cello_dev.bat               hot reload, like run_dev.bat
    build_cello_release.bat         build\cello_helper.exe   (or ./build_cello_release.sh)

The fingerboard is the player's view down the neck: nut at the top, C string on the
left, every place a finger can stop a string from the open string to the end of the
board, spaced as they really are (closer together further down). Point at a note on the
sheet and every place it can be played lights up; while playing, the current layer's
sounding notes light up; click a circle to hear it. The key buttons show only the notes
of that key (**All** shows every position, **Song** picks the song's key). The position
buttons (or the mouse wheel over the board) choose a hand position, 1st by default, and
draw a line across the board for each finger, labelled f1–f4 at the right edge.

It saves to `cello_songs\`. It can open anything in `songs\` or `imports\` too: every
layer becomes a cello, and Save puts the result in `cello_songs\`, never over the original.

## Using it

| | |
|---|---|
| **Place a note** | pick a length on the left (`1`–`6`, `.` dotted, `T` triplet), click a slot |
| **Sharps / flats** | the key signature decides; hold `Shift` for ♯, `Ctrl` for ♭, or use the accidental buttons |
| **Edit** | drag to move, right-click to delete, mouse wheel on a note = up/down a semitone |
| **Key lines** | the **lines** button next to the key: rows the key signature sharpens or flattens are tinted and named (F#, Bb) in the note column, and the rows of the key's home chord are marked - tonic brightest, 3rd and 5th fainter. Each row also shows its frequency ratio to a reference note (the tonic at or below the layer's first note): with C5 as 1:1, C6 is 2:1, G5 3:2, E5 5:4, C4 1:2. Right-click a row's name to make it the reference; right-click it again for automatic. On by default |
| **Sound effects** | the **SFX** button (top right): every sound effect in `sounds/`, click to hear; "many at once" fires N of one over a few seconds, bunched on a bell curve (e.g. 100 muskets in 2 s), with a chart of when each fell |
| **Octave copy** | `Ctrl`+click a note: a copy of it an octave lower, same place and length; `Shift`+click: an octave higher |
| **Selected note** | `↑`/`↓` a staff step, `Shift+↑/↓` a semitone, `←`/`→` a slot, `Del` removes it |
| **Fine grid** | hold `Alt` to snap to 32nds |
| **Layers** | `+ Add instrument`; click a layer to edit it; `M` mute, `S` solo (live, even mid-song); `Tab` next layer |
| **Play** | `Space` from this page, `Shift+Space` from the start. **Follow** turns pages with the playhead |
| **Pages** | `PgUp`/`PgDn`, `[` `]`, `←`/`→` with nothing selected, or click the page strip |
| **Undo** | `Ctrl+Z`, `Ctrl+Y` / `Ctrl+Shift+Z` |
| **Files** | `Ctrl+S` save, `Ctrl+O` open, `Ctrl+N` new, `Ctrl+E` export WAV |
| **Import** | put `.mid` files in `imports\` and Open them, or drag a `.mid` / `.song` onto the window |
| **Export** | WAV built in; MP3 / OGG / FLAC light up when `ffmpeg` is on PATH |
| **Sound mode** | the 8-bit button: click cycles **4-bit** (NES 16-step volume, grittiest), **8-bit** (default), **16-bit** (a player's touch: tuning, vibrato and bow scratch vary note to note), **32-bit** (modelled bowed strings and wooden bodies); right-click goes back. Export uses it too |
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
| `cello_songs/` | the Cello Helper's songs |
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
