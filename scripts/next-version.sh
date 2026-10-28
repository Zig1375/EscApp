#!/bin/sh
# Prints the next release's version and build number: "1.0.7 7".
# The first two parts are ESCAPP_VERSION in project.yml. The build number is one more than the highest last part
# of any vX.Y.Z tag, so builds count 1, 2, 3… and keep counting when ESCAPP_VERSION changes (macOS compares
# CFBundleVersion across versions). Needs the tags: `git fetch --tags`.
set -eu
cd "$(dirname "$0")/.."

base=$(sed -n 's/^ *ESCAPP_VERSION: *"\([0-9]*\.[0-9]*\)".*/\1/p' project.yml)
[ -n "$base" ] || { echo "ESCAPP_VERSION not found in project.yml" >&2; exit 1; }

last=$(git tag --list 'v*.*.*' | sed -n 's/^v[0-9]*\.[0-9]*\.\([0-9]*\)$/\1/p' | sort -n | tail -1)
build=$(( ${last:-0} + 1 ))
echo "$base.$build $build"
