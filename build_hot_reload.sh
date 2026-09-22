#!/usr/bin/env bash
# Build the app as a shared library. Safe to run while the app is running:
# the host copies the library before loading it, so this can overwrite it.
set -eu
cd "$(dirname "$0")"
mkdir -p build/hot_reload

# RAYLIB_SHARED: the library must share one raylib with every reload of
# itself, or each reload brings a fresh, uninitialised copy (no window, no
# audio device).
ODIN_ROOT="$(odin root)"
odin build source -build-mode:dll -define:RAYLIB_SHARED=true \
    -extra-linker-flags:"-Wl,-rpath $ODIN_ROOT/vendor/raylib/linux" \
    -out:build/hot_reload/game.so -debug "$@"

# Build the host only if it is not already running.
if ! pgrep -f build/8bit_music_box_dev > /dev/null 2>&1; then
    odin build main_hot_reload -out:build/8bit_music_box_dev -debug "$@"
fi
echo "ok — run ./build/8bit_music_box_dev"
