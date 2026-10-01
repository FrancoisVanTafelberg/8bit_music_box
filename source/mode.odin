package app

/*
    Names and a few fixed choices.

    There used to be two programs built from this code, the music box and the
    Cello Helper (-define:CELLO=true). The Cello Helper is now the Helper, a
    mode of the music box for every string instrument: helper.odin.
*/

APP_TITLE :: "8-Bit Music Box"
BARS_PER_PAGE :: 4 // a song's length is kept to whole grid pages

// Bars on a page: the grid's four, or the Score view's lines of bars
// (score.odin).
page_bars :: proc() -> i32 {
	return g.view == .Score ? score_bars_per_system() * SCORE_SYSTEMS : BARS_PER_PAGE
}

// Where the Cello Helper used to save. Open still lists what is in it.
CELLO_DIR :: "cello_songs"

LAST_SONG_FILE :: "last_song.txt"
