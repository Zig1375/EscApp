import Foundation

/// The settings a game last worked with, kept in its `.plaviox` so they travel with the folder. A game copied from
/// another Mac or sent over the internet starts with them; only when they don't work here does Plaviox look for
/// others, as on any first launch.
///
/// Values are strings, as in the game database (`KnownGame`): one this app doesn't know is ignored instead of making
/// the file unreadable.
public struct RecommendedSettings: Codable, Sendable, Equatable {
    public var backend: String?
    public var windows: String?
    public var chromium: String?

    public init(backend: String? = nil, windows: String? = nil, chromium: String? = nil) {
        self.backend = backend
        self.windows = windows
        self.chromium = chromium
    }

    public init(backend: GraphicsBackend, windows: WindowsVersion, chromium: ChromiumApp.Mode?) {
        self.init(backend: backend.rawValue, windows: windows.wineValue, chromium: chromium?.rawValue)
    }

    public var graphicsBackend: GraphicsBackend? { backend.flatMap(GraphicsBackend.init(rawValue:)) }
    public var windowsVersion: WindowsVersion? { windows.flatMap(WindowsVersion.init(wineValue:)) }
    public var chromiumMode: ChromiumApp.Mode? { chromium.flatMap(ChromiumApp.Mode.init(rawValue:)) }

    /// Nothing here this app can use.
    public var isEmpty: Bool { graphicsBackend == nil && windowsVersion == nil && chromiumMode == nil }
}

extension GameIdentifier {
    /// The settings in the game's `.plaviox`, if it is still this game's: a store game has none, and a folder can
    /// be reused by another game.
    public static func recommended(for game: GameRecord) -> RecommendedSettings? {
        guard game.store == nil, let marker = marker(in: folder(of: game)), marker.id == game.id,
              let settings = marker.recommended, !settings.isEmpty else { return nil }
        return settings
    }

    /// Keeps the settings the game just worked with in its `.plaviox`; nil removes them ("Find Launch Settings
    /// Again"). Only a `.plaviox` that names this game is touched, and only when something changes.
    public static func recommend(_ settings: RecommendedSettings?, for game: GameRecord) {
        let folder = folder(of: game)
        guard game.store == nil, var marker = marker(in: folder), marker.id == game.id,
              marker.recommended != settings else { return }
        marker.recommended = settings
        try? write(marker, in: folder)
    }

    private static func folder(of game: GameRecord) -> URL {
        URL(filePath: game.folder, directoryHint: .isDirectory)
    }
}
