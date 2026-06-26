#!/bin/sh
# Build the headless fight simulator (Phase 0 harness).
# Compiles the SE engine + the no-op platform layer + the sim. Clang directly,
# not Xcode (this is a standalone headless CLI, separate from the app target).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/../../Engine"
mkdir -p "$HERE/build"
clang -I "$ENGINE" -I "$HERE" -DFIGHTSIM -w \
    "$ENGINE"/*.c \
    "$HERE"/fightsim.c \
    "$HERE"/sim.c \
    "$HERE"/platform_stubs.c \
    -o "$HERE/build/fightsim" -lm
echo "built: $HERE/build/fightsim"
