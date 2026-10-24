# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

EscApp is a Mac app (Apple Silicon, macOS 15+) that runs Windows games through Wine without the user ever seeing
bottles, prefixes or Wine. The design and milestones are in `docs/ARCHITECTURE.md` (Russian); read it before
changing behaviour. The user speaks Russian: answer in Russian, but code, comments and commit messages are English.

## Commands

```bash
swift test                              # all tests (Swift Testing), no Wine needed
swift test --filter BackendPlanTests    # one suite or test
swift run escapp help                      # debugging CLI; ESCAPP_HOME=<dir> keeps it out of the real data
ESCAPP_INTEGRATION=1 ESCAPP_HOME=<dir> swift test --filter ProbeLaunchTests   # real Wine; needs `escapp runtime install`
swiftlint lint --strict                 # CI fails on any warning
scripts/check-translations.py .build/xcode   # after an app build: every UI string needs a Russian translation
xcodegen generate                       # EscApp.xcodeproj from project.yml (the project file is not committed)
xcodebuild -project EscApp.xcodeproj -scheme EscApp -destination 'platform=macOS,arch=arm64' build
```

## Layout

- `Package.swift` at the root: `EscAppKit` (all logic, no UI), `EscAppCLI` (the `escapp` command as a testable library),
  `escapp` (entry point only).
- `App/EscApp`: the SwiftUI app. It depends on EscAppKit through the local package. Strings go in
  `Localizable.xcstrings` with English and Russian from the start; CI fails on an untranslated string.
  Use `Color.brand` for the brand colour (`Color.accentColor` follows the user's system accent).
- Components: `RuntimeManifest` (bundled `Sources/EscAppKit/Resources/runtime-manifest.json`, every download pinned
  by SHA-256), `ManifestUpdater` (daily fetch of the same file from `main`), `RuntimeInstaller` (staging folder,
  `RUNTIME.json` marker written last), `RuntimeCatalog` (installed vs. newest). `escapp runtime status|install`
  does the same as the app.
- Bottles: `BottleManager` builds one template per runtime (`wineboot`, staging + `TEMPLATE.json`) and APFS-clones
  it per game (`BOTTLE.json`). `SharedProfile` links AppData and Saved Games to `EscApp/Profile` in the template.
  `WineRegistry` edits `user.reg` as text (only while the bottle's wineserver is stopped).
- Games: `GameIdentifier` finds the game for an exe via the `.escapp` file in its root folder, then last path, then a
  fingerprint; `GameLibrary` is `Games.json`. `escapp game identify|prepare|list` exercises both.
- Launching: `ExecutableInfo` reads an exe (format, imports → DirectX, name, icon, DPI) with a bounds-checked
  PE reader; `BackendPlan` orders backends; `GameLauncher` prepares the bottle and runs `wine <exe>` from the
  backend's own Wine tree (`BackendTree`: APFS clone of `wine` with DXVK/DXMT builtin DLLs in `lib/wine`;
  Wine won't take those DLLs from a bottle). Logs go to `Logs/<game-id>/`. `escapp inspect|run` do the same.
- `Tests/Fixtures/probes`: tiny D3D9/D3D11 test programs (32/64-bit) with sources and `build.sh` (mingw-w64).
  They are PE fixtures for unit tests and print `PROBE … OK` when they render on real Wine.
- Wine is WhiskyWine 3.1.1 (Wine 11.0) for now: DXMT needs `macdrv_functions` exported from `winemac.so`,
  which Gcenx builds lack. EscApp's own Wine build is planned.
- `AppPaths` is the only place that builds paths under `~/Library/Application Support/EscApp` (`ESCAPP_HOME` overrides).

## Rules

- Logic that can be "input → result" is a pure function with tests (environment, backend order, scaling,
  game identity, log parsing). Processes, files and the registry stay a thin layer on top.
- Anything EscApp puts into a bottle is recorded in a marker so EscApp only ever removes its own files.
- Every download of something EscApp runs is pinned by SHA-256 in the runtime manifest. Nothing sends data about
  the player anywhere. Pictures of a game from its store's public pages (`SteamScreenshots`: the request names only
  the app id) are fetched, kept in `Artwork/` and never run.
- Host environment reaches Wine only through `WineEnvironment.hostAllowlist`; per-game user settings apply last.
- Doc comments explain *why*, naming the game or failure that motivated the code.
- User-facing text is plain, without Wine jargon ("bottle", "prefix", "DLL override" never appear in the UI).
- Clean up after every task. Test homes (`ESCAPP_HOME`), bottles, unpacked runtimes, downloaded installers and
  apps, worktrees and build caches add up to tens of gigabytes (once 140 GB in `/private/tmp`, leaving the disk
  full). When a task is done, delete everything it created for testing, stop the Wine processes it started
  (`wineserver -k` for each test bottle), and keep only what the next step really needs, saying what and why.
  Never touch the user's own `~/Library/Application Support/EscApp`.

## Sibling projects (reference only)

`../mapc-engine` (Apache-2.0) and `../Whisky` (GPL-3.0) solve similar problems and were studied while designing
EscApp. Don't copy code from either: Whisky's license is incompatible, and EscApp reimplements ideas on its own terms.
