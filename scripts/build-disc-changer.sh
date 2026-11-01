#!/bin/sh
# Builds tools/disc-changer/changer.c into the MagicKettleKit resource `DiscDrive.change` runs in a bottle.
# Needs `brew install mingw-w64`. The result is committed, so building Magic Kettle doesn't need MinGW.
set -eu
cd "$(dirname "$0")/.."
x86_64-w64-mingw32-gcc -O2 -static -s \
    -o Sources/MagicKettleKit/Resources/disc-changer.exe tools/disc-changer/changer.c
shasum -a 256 Sources/MagicKettleKit/Resources/disc-changer.exe
