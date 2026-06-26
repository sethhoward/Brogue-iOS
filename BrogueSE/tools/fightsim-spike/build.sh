#!/bin/sh
# Build and run the headless fight-simulator de-risking spike.
# Compiles the whole engine + a no-op platform layer + a tiny main that runs
# attack() on a stub grid. See docs/design/fight-simulator.md §8.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/../../Engine"
mkdir -p "$HERE/build"

# Spike 1: melee attack() on a stub grid.
clang -I "$ENGINE" -w \
    "$ENGINE"/*.c \
    "$HERE/main.c" \
    "$HERE/platform_stubs.c" \
    -o "$HERE/build/spike" -lm
echo "built: $HERE/build/spike"
"$HERE/build/spike"

# Spike 2: SE lightning chain/stun ramps via the real zap() bolt path.
clang -I "$ENGINE" -w \
    "$ENGINE"/*.c \
    "$HERE/bolt_main.c" \
    "$HERE/platform_stubs.c" \
    -o "$HERE/build/spike-bolt" -lm
echo "built: $HERE/build/spike-bolt"
"$HERE/build/spike-bolt"
