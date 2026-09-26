Instrument files
================

Every instrument the app has is defined here - none are built into the code.
Every .inst file in this folder is read when the app starts, and again when you
press F7, so you can change an instrument and hear it without a rebuild.

  strings.inst       violin, viola, cello, contrabass, harp
  woodwinds.inst     piccolo, fife, flute, oboe, english horn, clarinets, bassoons
  brass.inst         french horn, trumpet, trombone, tuba
  percussion.inst    timpani, mallets, bells, snare, field drum, bass drum, cymbals
  keyboards.inst     piano, harpsichord, celesta, organ
  voices.inst        choir
  chip.inst          the NES channels: pulse lead, square lead, triangle bass
  field_music.inst   extras for the fife-and-drum corps: a softer 2nd fife, side drum, bugle

Add your own files alongside. A file whose name starts with '_' is not loaded,
which is an easy way to switch one off. If this folder is missing or empty,
the app still runs, playing everything as a plain square wave, and says so.

The format, one block per instrument:

  define_instrument bugle          # the key songs use: "instrument bugle"
  based_on trumpet                 # optional: start from another instrument
  name "Bugle"
  family brass                     # strings woodwinds brass percussion keyboards voices chip
  range G4 G5                      # sounding, lowest and highest; pitch names or MIDI numbers
  wave pulse 0.5                   # pulse <duty> | triangle | saw | sine | noise
  layer triangle 0.3 12            # second oscillator: <wave> <mix 0..1> <semitones up>; or "layer none"
  envelope 0.02 0.1 0.8 0.06       # attack decay sustain release (seconds; sustain is a level)
  vibrato 5 0.1 0.2                # rate Hz, depth semitones, delay seconds
  sweep -0.5 0.03                  # the note starts this many semitones off, and glides home
  breath 0.02                      # white noise mixed in
  tone 0.7                         # low-pass filter: 1 = open, lower = darker
  metallic 0                       # noise only: the NES "short" mode (clangy)
  gain 0.5
  pan 0.2                          # -1 left .. +1 right
  color 255 200 80                 # its colour on the sheet
  model bowed 0.5 0.12             # 32-bit mode only: a simulated bowed string
                                   #   (bow pressure 0..1, bow position 0..0.5 from the bridge)
  resonance 200 3 4                # 32-bit mode only: a body resonance, Hz Q dB (up to 4
                                   #   lines; "resonance none" clears them)
  board C2 G2 D3 A3                # a fingerboard for the Helper: the open strings,
                                   #   lowest first, up to 6 ("board none" removes it)
  board_mm 695 23 47               # string length nut to bridge; outer strings' spread
                                   #   at the nut and at the bridge (mm)
  board_semis 29 20                # semitones on the board; how far the Helper shows
                                   #   and tracks (a cello's thumb position)
  frets 0                          # 1 = fretted (the guitar): frets drawn, notes
                                   #   between them
  position "1st position" 1st 2 3 4 5   # a hand position: name, button label, where
                                   #   fingers 1-4 stop (semitones above open, 0 =
                                   #   unused), and optionally the thumb (up to 10)
  board_default 1st                # the position the Helper starts in
  keyboard 1                       # instead of a board: the Helper shows a keyboard
                                   #   (the piano and the other keyboards)
  end

Every line inside a block is optional. A block starts from:
  1. its based_on instrument, if it has one - from any file, in any order;
  2. otherwise the instrument that already has that key, from a file whose
     name sorts earlier - so a file of your own (say "zz_my_tweaks.inst")
     can change ONLY the violin's volume and leave the rest of it alone:
         define_instrument violin
         gain 0.4
         end
  3. otherwise a plain square wave.

The same blocks can go inside a .song file, so that song carries its own
instruments and plays the same on any copy of the app. The "embed" button
under the instrument panel does that for you. A song's own definition wins
over a file with the same key.

In the instrument picker, (song) marks an instrument defined in the open song.
