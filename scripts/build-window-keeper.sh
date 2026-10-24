#!/bin/sh
# Builds tools/window-keeper/keeper.c into the EscAppKit resource `WindowKeeper` starts beside a game.
# Needs `brew install mingw-w64`. The result is committed, so building EscApp doesn't need MinGW.
set -eu
cd "$(dirname "$0")/.."
x86_64-w64-mingw32-gcc -O2 -municode -mwindows -static -s \
    -o Sources/EscAppKit/Resources/window-keeper.exe tools/window-keeper/keeper.c
shasum -a 256 Sources/EscAppKit/Resources/window-keeper.exe
