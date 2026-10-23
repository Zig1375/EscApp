#!/bin/sh
# Rebuilds the probe executables committed next to this script. Needs `brew install mingw-w64`; the outputs are
# checked in so tests and CI never need a Windows compiler.
set -eu
cd "$(dirname "$0")"
python3 make-icon.py probe.ico
for arch in i686:x86 x86_64:x64; do
    triple="${arch%%:*}-w64-mingw32"; name="${arch##*:}"
    "$triple-windres" probe.rc -O coff -o "probe-$name.res"
    "$triple-gcc" -O2 -s -static -o "d3d11-$name.exe" d3d11probe.c "probe-$name.res" -ld3d11 -ldxguid
    "$triple-gcc" -O2 -s -static -o "d3d9-$name.exe" d3d9probe.c "probe-$name.res" -ld3d9
    rm "probe-$name.res"
done
rm probe.ico
ls -l *.exe
