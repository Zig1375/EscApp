#!/usr/bin/env python3
"""Fails when a UI string has no Russian translation.

Reads the keys the Swift compiler extracted during the last app build (.stringsdata files, written because
SWIFT_EMIT_LOC_STRINGS is on) and compares them with App/Rum/Localizable.xcstrings. Run after xcodebuild:

    scripts/check-translations.py <derived-data-path>
"""
import glob
import json
import sys

derived = sys.argv[1] if len(sys.argv) > 1 else ".build/xcode"
keys = set()
for path in glob.glob(f"{derived}/**/Rum.build/**/*.stringsdata", recursive=True):
    with open(path) as f:
        for table in json.load(f).get("tables", {}).values():
            keys.update(entry["key"] for entry in table)
if not keys:
    sys.exit(f"No extracted strings under {derived}; build the app first.")

with open("App/Rum/Localizable.xcstrings") as f:
    catalog = json.load(f)["strings"]

missing = []
for key in sorted(keys):
    entry = catalog.get(key, {})
    if entry.get("shouldTranslate") is False:
        continue
    if entry.get("localizations", {}).get("ru", {}).get("stringUnit", {}).get("state") != "translated":
        missing.append(key)

if missing:
    print("Strings without a Russian translation in App/Rum/Localizable.xcstrings:")
    for key in missing:
        print(f"  {key!r}")
    sys.exit(1)
print(f"All {len(keys)} UI strings are translated.")
