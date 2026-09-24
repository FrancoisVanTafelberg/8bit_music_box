#!/usr/bin/env bash
# Cello Helper: build it as a shared library for hot reload (source/ with
# -define:CELLO=true, into its own cello.so), and its host if not running.
set -eu
cd "$(dirname "$0")"
mkdir -p build/hot_reload
ODIN_ROOT="$(odin root)"
odin build source -build-mode:dll -define:RAYLIB_SHARED=true -define:CELLO=true \
    -extra-linker-flags:"-Wl,-rpath $ODIN_ROOT/vendor/raylib/linux" \
    -out:build/hot_reload/cello.so -debug "$@"
if ! pgrep -f build/cello_helper_dev > /dev/null 2>&1; then
    odin build main_hot_reload -define:GAME_NAME=cello -out:build/cello_helper_dev -debug "$@"
fi
echo "ok — run ./build/cello_helper_dev"
