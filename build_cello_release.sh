#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")"
mkdir -p build
odin build main_release -define:CELLO=true -out:build/cello_helper -o:speed -no-bounds-check "$@"
echo "ok — ./build/cello_helper"
