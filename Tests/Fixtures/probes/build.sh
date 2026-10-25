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
for arch in x86_64:x64; do
    triple="${arch%%:*}-w64-mingw32"; name="${arch##*:}"
    "$triple-gcc" -O2 -s -static -o "crash-$name.exe" crashprobe.c -ld3d11
    "$triple-dlltool" -d missing.def -l libmissing.a
    "$triple-gcc" -O2 -s -static -o "missing-$name.exe" missingprobe.c libmissing.a
    rm libmissing.a
done
i686-w64-mingw32-windres setup.rc -O coff -o setup.res
i686-w64-mingw32-gcc -municode -O2 -s -static -o setup-x86.exe setupprobe.c setup.res -lole32 -luuid -lshell32
i686-w64-mingw32-gcc -municode -DNSIS_STYLE -O2 -s -static -o nsis-x86.exe setupprobe.c -lole32 -luuid -lshell32
rm setup.res
i686-w64-mingw32-gcc -O2 -s -static -o lowres-x86.exe lowresprobe.c -ld3d9 -lgdi32
i686-w64-mingw32-gcc -O2 -s -static -o cd-x86.exe cdprobe.c
x86_64-w64-mingw32-gcc -O2 -s -static -o stretch-x64.exe stretchprobe.c -ld3d9 -ld3d11 -ldxguid -lgdi32
rm probe.ico
ls -l *.exe
