#!/usr/bin/env python3
"""Fails when a UI string is missing a translation into any of the app's languages.

Reads the keys the Swift compiler extracted during the last app build (.stringsdata files, written because
SWIFT_EMIT_LOC_STRINGS is on) and compares them with App/EscApp/Localizable.xcstrings. Run after xcodebuild:

    scripts/check-translations.py <derived-data-path>
"""
import glob
import json
import sys

derived = sys.argv[1] if len(sys.argv) > 1 else ".build/xcode"
keys = set()
for path in glob.glob(f"{derived}/**/EscApp.build/**/*.stringsdata", recursive=True):
    with open(path) as f:
        for table in json.load(f).get("tables", {}).values():
            keys.update(entry["key"] for entry in table)
if not keys:
    sys.exit(f"No extracted strings under {derived}; build the app first.")

with open("App/EscApp/Localizable.xcstrings") as f:
    catalog = json.load(f)["strings"]

# The languages of Settings → General → Language (AppLanguage), English being the source.
LANGUAGES = ["de", "es", "fr", "it", "ja", "ko", "ru", "zh-Hans"]

missing = []
for key in sorted(keys):
    entry = catalog.get(key, {})
    if entry.get("shouldTranslate") is False:
        continue
    for lang in LANGUAGES:
        unit = entry.get("localizations", {}).get(lang, {})
        # Plural forms (one/few/many) live under "variations" instead of a single "stringUnit".
        if unit.get("stringUnit", {}).get("state") != "translated" and "variations" not in unit:
            missing.append((lang, key))

if missing:
    print("Strings without a translation in App/EscApp/Localizable.xcstrings:")
    for lang, key in missing:
        print(f"  {lang}: {key!r}")
    sys.exit(1)
print(f"All {len(keys)} UI strings are translated.")
