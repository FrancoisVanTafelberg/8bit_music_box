package music

/*
    Clefs, for the Score view of the sheet (source/score.odin): which staff an
    instrument's part is written on, as real parts are.

    From the instrument files, like everything else about an instrument:

        clef treble                 # a violin
        clef bass tenor treble      # a cello: bass, and tenor or treble
                                    #   for the lines that sit high
        clef grand                  # a piano: treble and bass, braced

    With more than one, the Score view picks one for each line of music: the
    one it was already on if the notes fit it, else the first in the list that
    needs the fewest ledger lines.

    The notes are always shown at the pitch they sound. The octave clefs are
    for the instruments whose parts are written an octave away from it:
    treble_8vb (the guitar, the tenor voice), treble_8va (piccolo,
    glockenspiel, celesta), bass_8vb (contrabass, contrabassoon) - the little
    8 on the clef says the staff reads an octave lower or higher.

    No clef line: one is guessed from the range (clef_guess).
*/

Clef :: enum u8 {
	Treble,
	Bass,
	Alto,
	Tenor,
	Treble_8vb,
	Treble_8va,
	Bass_8vb,
	Percussion,
	Grand, // treble and bass together, braced: the keyboards and the harp
}

CLEF_NAME := [Clef]string {
	.Treble     = "treble",
	.Bass       = "bass",
	.Alto       = "alto",
	.Tenor      = "tenor",
	.Treble_8vb = "treble_8vb",
	.Treble_8va = "treble_8va",
	.Bass_8vb   = "bass_8vb",
	.Percussion = "percussion",
	.Grand      = "grand",
}

MAX_CLEFS :: 3

clef_from :: proc(s: string) -> (Clef, bool) {
	for n, c in CLEF_NAME do if n == s do return c, true
	return .Treble, false
}

// The staff step (theory.odin: C0 = 0, C4 = 28) on the staff's middle line.
// Grand: the treble staff's; its bass staff is clef_mid(.Bass).
clef_mid :: proc(c: Clef) -> int {
	switch c {
	case .Treble, .Percussion, .Grand:
		return 34 // B4
	case .Bass:
		return 22 // D3
	case .Alto:
		return 28 // C4
	case .Tenor:
		return 26 // A3
	case .Treble_8vb:
		return 27 // B3
	case .Treble_8va:
		return 41 // B5
	case .Bass_8vb:
		return 15 // D2
	}
	return 34
}

// Where a key signature's accidentals sit: every sharp (or flat) is placed
// in the seven steps starting this far from the middle line, so each clef
// gets the familiar zig-zag (treble sharps F5 C5 G5 D5 A4 E5 B4).
clef_sharp_low :: proc(c: Clef) -> int {
	switch c {
	case .Bass, .Bass_8vb:
		return -3
	case .Alto, .Tenor:
		return -2
	case .Treble, .Treble_8vb, .Treble_8va, .Percussion, .Grand:
	}
	return -1
}

clef_flat_low :: proc(c: Clef) -> int {
	switch c {
	case .Bass, .Bass_8vb:
		return -5
	case .Alto:
		return -4
	case .Tenor:
		return -2
	case .Treble, .Treble_8vb, .Treble_8va, .Percussion, .Grand:
	}
	return -3
}

// The instrument's clefs, from its file, or guessed from its range.
inst_clefs :: proc(ins: ^Instrument) -> []Clef {
	if ins.n_clefs > 0 do return ins.clefs[:ins.n_clefs]
	ins.clefs[0] = clef_guess(ins.lo, ins.hi)
	return ins.clefs[:1]
}

// Two octaves and more either side of middle C: both staves. Otherwise the
// staff its middle is nearer.
clef_guess :: proc(lo, hi: i32) -> Clef {
	if lo <= 48 && hi >= 72 do return .Grand
	return (lo + hi) / 2 < 60 ? .Bass : .Treble
}
