# EscApp

EscApp plays Windows games on Apple Silicon Macs. Double-click a game's `.exe` in Finder and it runs: EscApp downloads
Wine and the graphics layers, sets up a private Windows for the game, picks the settings that work and remembers
them. There are no bottles or prefixes to manage, and no store is required.

Status: early development (milestone M0, the project skeleton). See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
for the design and the plan (in Russian).

## Building

Needs macOS 15+, Apple Silicon and Xcode 16+.

```bash
swift test                 # EscAppKit and CLI tests, no Wine needed
swift run escapp help         # debugging CLI
brew install xcodegen
xcodegen generate          # creates EscApp.xcodeproj from project.yml
open EscApp.xcodeproj
```

## License

Apache-2.0. Wine, DXVK, DXMT and Wine Mono are downloaded separately under their own licenses.
