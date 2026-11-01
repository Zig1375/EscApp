#!/bin/sh
# Builds tools/chromium-helper/helper.c into the PlavioxKit resource that `ChromiumHelper` installs.
# Needs `brew install mingw-w64`. The result is committed, so building Plaviox doesn't need MinGW.
set -eu
cd "$(dirname "$0")/.."
x86_64-w64-mingw32-gcc -O2 -municode -mwindows -static -s \
    -o Sources/PlavioxKit/Resources/chromium-helper.exe tools/chromium-helper/helper.c
shasum -a 256 Sources/PlavioxKit/Resources/chromium-helper.exe
