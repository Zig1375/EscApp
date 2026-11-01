#!/bin/sh
# Prints a release's notes: release-notes/v<version>.md, then what the release job itself knows (the zip's SHA-256
# and size, the commit it was built from). Used by the release job in ci.yml.
#   scripts/release-notes.sh 1.0.7 MagicKettle-1.0.7.zip <commit>
set -eu
version=$1 zip=$2 commit=$3
notes="$(dirname "$0")/../release-notes/v$version.md"
[ -f "$notes" ] || { echo "no release notes: release-notes/v$version.md" >&2; exit 1; }

cat "$notes"
cat <<MD

## Download

\`$(basename "$zip")\`, built by the release job at $commit. Open it and move **Magic Kettle** to **Applications**;
the [README](https://github.com/Zig1375/MagicKettle#install) says how to open it the first time. Magic Kettle 1.0.4
and later update themselves.

- sha256: \`$(shasum -a 256 "$zip" | cut -d' ' -f1)\`
- size: $(stat -f%z "$zip") bytes
MD
