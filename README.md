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

## Using it

| | |
|---|---|
| **Place a note** | pick a length on the left (`1`–`6`, `.` dotted, `T` triplet), click a slot |
| **Sharps / flats** | the key signature decides; hold `Shift` for ♯, `Ctrl` for ♭, or use the accidental buttons |
| **Edit** | drag to move, right-click to delete, mouse wheel on a note = up/down a semitone |
| **Selected note** | `↑`/`↓` a staff step, `Shift+↑/↓` a semitone, `←`/`→` a slot, `Del` removes it |
| **Fine grid** | hold `Alt` to snap to 32nds |
| **Layers** | `+ Add instrument`; click a layer to edit it; `M` mute, `S` solo; `Tab` next layer |
| **Play** | `Space` from this page, `Shift+Space` from the start. **Follow** turns pages with the playhead |
| **Pages** | `PgUp`/`PgDn`, `[` `]`, `←`/`→` with nothing selected, or click the page strip |
| **Undo** | `Ctrl+Z`, `Ctrl+Y` / `Ctrl+Shift+Z` |
| **Files** | `Ctrl+S` save, `Ctrl+O` open, `Ctrl+N` new, `Ctrl+E` export WAV |
| **Import** | put `.mid` files in `imports\` and Open them, or drag a `.mid` / `.song` onto the window |
| **Export** | WAV built in; MP3 / OGG / FLAC light up when `ffmpeg` is on PATH |
| **4-bit** | toggles NES-style 16-step volume (on = grittier, off = smoother) |
| `F7` | reload the instrument files |
| `F11` | fullscreen |

Rows the active instrument cannot play are shaded and refuse clicks.

## Folders

| | |
|---|---|
| `source/` | package `app`: the editor. All state in one block for hot reload |
| `source/music/` | package `music`, no raylib: theory, song model, `.song` format, instruments, synth, WAV, MIDI import |
| `source/rlu/` | virtual resolution (1280 × 720 canvas), from Animal Kingdoms |
| `tools/render/` | `odin run tools/render -- songs/ode_to_joy.song` renders to WAV with no window |
| `instruments/` | every instrument, as text files (`.inst`): add or change them without a rebuild, F7 reloads. See `instruments/README.txt` |
| `songs/` | saved songs (plain text, hand-editable) |
| `imports/` | MIDI files to open |
| `exports/` | rendered audio |
| `songs_that_cannot_be_used_for_legal_reasons/` | songs and MIDI of music that is **not** public domain: playable here, never copied to the repo or committed |

## Copying to the GitHub repo

`E:\.workspace\8bit_music_box` is the git repository that talks to GitHub; this
folder is where the work happens. To bring the repo up to date:

    copy_to_repo.bat -DryRun      say what would happen, change nothing
    copy_to_repo.bat              back up, clear, copy (asks first)
    copy_to_repo.bat -Force -Prune 5

It backs the repo folder up to `8bit_music_box.bak.YYYY-MM-DD-HH-MM` first, keeps its
`.git` and `.gitignore`, and does not copy `.temp`, `build`, `exports`,
`last_song.txt` or `songs_that_cannot_be_used_for_legal_reasons`. Nothing is written back here.
