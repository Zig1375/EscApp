# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Rum is a Mac app (Apple Silicon, macOS 15+) that runs Windows games through Wine without the user ever seeing
bottles, prefixes or Wine. The design and milestones are in `docs/ARCHITECTURE.md` (Russian); read it before
changing behaviour. The user speaks Russian: answer in Russian, but code, comments and commit messages are English.

## Commands

```bash
swift test                              # all tests (Swift Testing), no Wine needed
swift test --filter BackendPlanTests    # one suite or test
swift run rum help                      # debugging CLI; RUM_HOME=<dir> keeps it out of the real data
swiftlint lint --strict                 # CI fails on any warning
scripts/check-translations.py .build/xcode   # after an app build: every UI string needs a Russian translation
xcodegen generate                       # Rum.xcodeproj from project.yml (the project file is not committed)
xcodebuild -project Rum.xcodeproj -scheme Rum -destination 'platform=macOS,arch=arm64' build
```

## Layout

- `Package.swift` at the root: `RumKit` (all logic, no UI), `RumCLI` (the `rum` command as a testable library),
  `rum` (entry point only).
- `App/Rum`: the SwiftUI app. It depends on RumKit through the local package. Strings go in
  `Localizable.xcstrings` with English and Russian from the start; CI fails on an untranslated string.
  Use `Color.rum` for the brand colour (`Color.accentColor` follows the user's system accent).
- Components: `RuntimeManifest` (bundled `Sources/RumKit/Resources/runtime-manifest.json`, every download pinned
  by SHA-256), `ManifestUpdater` (daily fetch of the same file from `main`), `RuntimeInstaller` (staging folder,
  `RUNTIME.json` marker written last), `RuntimeCatalog` (installed vs. newest). `rum runtime status|install`
  does the same as the app.
- `RumPaths` is the only place that builds paths under `~/Library/Application Support/Rum` (`RUM_HOME` overrides).

## Rules

- Logic that can be "input → result" is a pure function with tests (environment, backend order, scaling,
  game identity, log parsing). Processes, files and the registry stay a thin layer on top.
- Anything Rum puts into a bottle is recorded in a marker so Rum only ever removes its own files.
- Every download is pinned by SHA-256 in the runtime manifest. Nothing sends data anywhere.
- Host environment reaches Wine only through `WineEnvironment.hostAllowlist`; per-game user settings apply last.
- Doc comments explain *why*, naming the game or failure that motivated the code.
- User-facing text is plain, without Wine jargon ("bottle", "prefix", "DLL override" never appear in the UI).

## Sibling projects (reference only)

`../mapc-engine` (Apache-2.0) and `../Whisky` (GPL-3.0) solve similar problems and were studied while designing
Rum. Don't copy code from either: Whisky's license is incompatible, and Rum reimplements ideas on its own terms.
