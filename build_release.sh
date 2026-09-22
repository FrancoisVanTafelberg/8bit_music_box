#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")"
mkdir -p build
odin build main_release -out:build/8bit_music_box -o:speed -no-bounds-check "$@"
echo "ok — run ./build/8bit_music_box"
