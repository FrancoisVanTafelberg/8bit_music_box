Sound effect files
==================

Sounds that are not music - a cannon, a musket volley, a sword clash - made from
the same chip oscillators as the orchestra. Every .sfx file in this folder is
read when a program loads the sounds (the editor: at start and on F7). A file
whose name starts with '_' is not loaded.

  battle.sfx     cannon, cannon_distant, musket, musket_volley, sword_clash,
                 sword_draw, ship_bell, splash

Hear them without a program:

  odin run tools/render -- sfx all            -> exports/<key>.wav
  odin run tools/render -- sfx cannon

Play them from a program:

  music.mixer_play_sfx(&mixer, "cannon")
  music.mixer_play_sfx(&mixer, "musket", pan = -0.5, vary = 1)   (vary: random
                                  pitch shift up to 1 semitone, so repeats differ)

The format
----------

A sound effect is a handful of voices, each an instrument playing one pitch:

  define_sfx cannon                # the key programs play it by
  name "Cannon"
  volume 1                         # the whole effect
  # voice <instrument> <pitch> <start s> <length s> [volume] [pan -1..1]
  voice boom    A1  0     0.9  1
  voice blast   C3  0     0.6  0.9
  voice rumble  C2  0.04  1.5  0.7
  end

  pitch    a note name (A1, F#6), a MIDI number (33), or a frequency (440hz).
           For a noise instrument it is how bright the hiss is: C2 a low roar,
           C7 a sharp crack.
  start    seconds after the effect begins: stagger voices for a ragged volley.
  length   seconds the note is held. A struck instrument (envelope sustain 0)
           rings for its own decay whatever the length.

A voice can use any orchestra instrument (instruments/*.inst) by its key, or one
defined in a .sfx file. Instruments defined here use exactly the .inst grammar
(see instruments/README.txt) and are kept apart from the orchestra, so they do
not turn up in the editor's instrument list:

  define_instrument boom
  wave triangle
  envelope 0.001 0.9 0 0.2         # sustain 0: struck, decays over 0.9 s
  sweep 14 0.07                    # starts 14 semitones high and falls: a thump
  end

Ideas that work:

  thump    triangle, big positive sweep, struck envelope, low pitch
  bang     noise, dark (tone 0.1 - 0.3), a fraction of a second
  crack    noise, bright (tone 1), a few hundredths of a second, high pitch
  metal    sine plus a sine layer at an inharmonic interval (17.3 or 13.1
           semitones, not 12 or 19), struck; add "metallic 1" noise for grind
  whoosh   noise with a negative sweep (rises into its pitch), slow attack
