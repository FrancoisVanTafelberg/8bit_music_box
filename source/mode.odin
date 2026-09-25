package app

/*
    One code base, two programs.

    8-Bit Music Box   the full editor: every instrument, 4 bars to a page.
    Cello Helper      the same editor with only the cello, a narrower panel,
                      and the Cello Fingerboard (fingerboard.odin) down the
                      right-hand side.

    Which one gets built is decided at compile time:

        odin build source ... -define:CELLO=true

    The build_cello_* scripts do that, and give the result its own names
    (build/cello_helper.exe, build/hot_reload/cello.dll), so both programs can
    be built and run side by side from the same folder.
*/

CELLO :: #config(CELLO, false)

APP_TITLE :: "Cello Helper" when CELLO else "8-Bit Music Box"
BARS_PER_PAGE :: 4

// The Cello Helper's only instrument.
CELLO_KEY :: "cello"
// Where the Cello Helper saves. It can open songs from songs/ too, but saves
// them here, so turning an orchestral song's layers into cellos never
// overwrites the original.
CELLO_DIR :: "cello_songs"

LAST_SONG_FILE :: "last_cello_song.txt" when CELLO else "last_song.txt"
