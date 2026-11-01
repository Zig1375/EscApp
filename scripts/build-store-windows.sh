#!/bin/sh
# Builds tools/store-windows/windows.c into the MagicKettleKit resource `StoreWindows` runs in a store's bottle.
# Needs `brew install mingw-w64`. The result is committed, so building Magic Kettle doesn't need MinGW.
set -eu
cd "$(dirname "$0")/.."
x86_64-w64-mingw32-gcc -O2 -municode -static -s \
    -o Sources/MagicKettleKit/Resources/store-windows.exe tools/store-windows/windows.c
shasum -a 256 Sources/MagicKettleKit/Resources/store-windows.exe
