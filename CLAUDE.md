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
scripts/check-translations.py .build/xcode   # after an app build: every UI string needs every translation
xcodegen generate                       # EscApp.xcodeproj from project.yml (the project file is not committed)
xcodebuild -project EscApp.xcodeproj -scheme EscApp -destination 'platform=macOS,arch=arm64' build
```

## Layout

- `Package.swift` at the root: `EscAppKit` (all logic, no UI), `EscAppCLI` (the `escapp` command as a testable library),
  `escapp` (entry point only).
- `App/EscApp`: the SwiftUI app. It depends on EscAppKit through the local package. Strings go in
  `Localizable.xcstrings` with every language of `AppLanguage` from the start (de, es, fr, it, ja, ko, ru, zh-Hans;
  English is the source); CI fails on an untranslated string.
  Use `Color.brand` for the brand colour (`Color.accentColor` follows the user's system accent).
  `GameCard` (library grid): a click on the card plays the game (or shows it while running); hover shows a play
  symbol and an About button; everything else is in the context menu.
- Components: `RuntimeManifest` (bundled `Sources/EscAppKit/Resources/runtime-manifest.json`, every download pinned
  by SHA-256), `ManifestUpdater` (daily fetch of the same file from `main`), `RuntimeInstaller` (staging folder,
  `RUNTIME.json` marker written last), `RuntimeCatalog` (installed vs. newest). `escapp runtime status|install`
  does the same as the app.
- Bottles: `BottleManager` builds one template per runtime (`wineboot`, staging + `TEMPLATE.json`) and APFS-clones
  it per game (`BOTTLE.json`). `SharedProfile` links AppData and Saved Games to `EscApp/Profile` in the template.
  `WineRegistry` edits `user.reg` as text (only while the bottle's wineserver is stopped).
- Games: `GameIdentifier` finds the game for an exe by the `.escapp` file in its root folder, and by nothing else; an
  exe without one is a new game. Store games are the exception: no `.escapp` is written into a store's folder, so an
  exe is matched to the store game whose program it is or whose folder holds it (`Games.json`, `StoreLibrary.sync`),
  and an unknown exe inside a store's bottle is refused. `.escapp` also carries `RecommendedSettings` (what the game
  last worked with), so a folder from another Mac tries those first and falls back to the usual search. `GameLibrary` is `Games.json`. `escapp game identify|prepare|list` exercises both.
- Launching: `ExecutableInfo` reads an exe (format, imports → DirectX, name, icon, DPI) with a bounds-checked
  PE reader (`unityplayer.dll` counts as Direct3D 11: Unity loads it at run time); `BackendPlan` orders backends
  by the newest Direct3D (11 → DXVK, DXMT, WineD3D; 9 and older → WineD3D; none found → DXVK, WineD3D);
  `GameLauncher` prepares the bottle and runs `wine <exe>` from the backend's own Wine tree (`BackendTree`: APFS clone of `wine` with DXVK/DXMT builtin DLLs in `lib/wine`;
  Wine won't take those DLLs from a bottle). Logs go to `Logs/<game-id>/`. `escapp inspect|run` do the same.
- RPG Maker XP/VX/VX Ace: `RPGMakerGame` reads `Game.ini`; the Run Time Package it names (`rtps` in the manifest,
  the publisher's own Inno Setup installer from its own server, which is the only place it may come from) is
  installed once by `RTPInstaller` into `EscApp/RTP` and linked into each bottle that needs it, with its registry
  value. `GameLanguage` starts Japanese games with `LC_ALL=ja_JP.UTF-8` (code page 932); `WindowsFonts` maps
  Japanese Windows font names to Arial Unicode MS. `RGSSArchive` reads the game's scripts out of its archive for
  `Graphics.resize_screen`, so the first launch is enlarged like later ones.
- Microsoft runtimes: `RedistNeeds` finds the Visual C++ (imports of every exe and DLL in the program's folder and
  two levels below, each by its own bitness) and .NET (`runtimeconfig.json`) a game needs; `RedistInstaller` runs
  Microsoft's installer (`redists` in the manifest) in the game's bottle, Wine's own copies set aside meanwhile, and
  records it in `REDISTS.json`. The launch sheet shows each one by name ("Installing components this game needs
  (1 of 2)"), RPG Maker's packages too.
- `Tests/Fixtures/probes`: tiny D3D9/D3D11 test programs (32/64-bit) with sources and `build.sh` (mingw-w64).
  They are PE fixtures for unit tests and print `PROBE … OK` when they render on real Wine.
- Wine is EscApp's own build (Wine 11.20, built and released by the sibling repo `../EscApp-Runtime`), with
  WhiskyWine 3.1.1 (Wine 11.0) still in the manifest as the older runtime. DXMT needs `macdrv_functions` exported
  from `winemac.so`, which stock and Gcenx builds lack; EscApp's build patches it in. Releasing it: run the Wine
  workflow by hand in `../EscApp-Runtime`, then replace the `wine-11.20-escapp-<n>` runtime here with the release's
  `escapp-wine-*.component.json` (version, url, sha256, size) and carry the `features` list (`osync`, `d3dmetal`)
  over by hand — the workflow's json has none. Check the published archive against the manifest by downloading it
  and its sha256. Every push to `main` that passes CI becomes a release (`ci.yml`), a documentation-only one too.
- DirectX 12: `D3DMetal` takes Apple's D3DMetal from the player's own download of Apple's "Evaluation environment for
  Windows games" (checked by Apple's signature, copied unchanged to `EscApp/D3DMetal`); EscApp never ships or
  downloads it, and nothing of Apple's goes into the repository. The `d3dmetal` backend needs a Wine with the
  `d3dmetal` feature and runs with `WINEMACSHAREDTSD=1`. `escapp d3dmetal status|import|remove`; Settings › DirectX 12.
- Stores: `Store` is only a store's name in `Games.json`; everything about one store is its `StoreModule`, a folder
  per store (`Sources/EscAppKit/Stores/Steam`, `.../Epic`). A new store is a type conforming to `StoreModule` (with
  a fixed `id` and `bottleNumber`, never reusing 3–5, which GOG Galaxy, the EA app and Ubisoft Connect had), its
  line in `Store.allCases`, and its logo, colour and purpose in the app's `StoreBar.swift`. A client whose own
  windows have a fixed pixel size sets `drawsAtScreenResolution = false` — Steam does, because Wine's Retina mode
  drew its update window and dialogs at half the size of the rest of its interface — and then macOS stretches the
  picture of its whole interface. Its games run without Retina too (`StoreClient.retina`): Retina belongs to the
  whole bottle, and a client started after a game wrote it there came out at half size. Their scale and DPI are
  still their own: `GameLauncher.drawing` is the one place that computes what is written into the bottle, and
  `StoreClient.needsRestart` says when a game's own settings mean the client must be restarted first.
- Game modules (`docs/GAME-MODULES.md`): what particular games need, as data in the sibling repo `../EscApp-Games`,
  whose CI builds `games.json`. `GameModulesUpdater` fetches it daily into `GameModules.json` (the app's copy is
  `Resources/game-modules.json`, rebuilt with `tools/build_index.py --output` there); `GameModules` finds a game's
  module (store id, exe SHA-256, exe name with ProductName, exe name) and turns its `launch` into a backend order
  and Windows version. Only `launch` (backend, Windows) is applied so far. `escapp module list|show|update`.
- `AppPaths` is the only place that builds paths under `~/Library/Application Support/EscApp` (`ESCAPP_HOME` overrides).

## Rules

- There is exactly one copy of the sources: this folder, with its uncommitted changes. Never copy the sources
  anywhere (scratchpad, `/tmp`, `git archive`, a clone, a worktree) to edit, build or run them. Build into
  `.build/xcode` from here; the app the user runs is `.build/xcode/Build/Products/Debug/EscApp.app`. A build from a
  copy once ran without the fixes in this folder, and a fix looked broken.
- Logic that can be "input → result" is a pure function with tests (environment, backend order, scaling,
  game identity, log parsing). Processes, files and the registry stay a thin layer on top.
- Anything EscApp puts into a bottle is recorded in a marker so EscApp only ever removes its own files.
- Every download of something EscApp runs is pinned by SHA-256 in the runtime manifest. Nothing sends data about
  the player anywhere. Pictures of a game from its store's public pages (`StoreScreenshots`, `EpicCovers`: a request
  names only the game) are fetched, kept in `Artwork/` and never run.
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
