import Foundation

/// Every folder EscApp uses on disk. Nothing else in EscAppKit builds these paths by hand.
///
/// `ESCAPP_HOME` replaces `~/Library/Application Support/EscApp` so the CLI and tests can work in a scratch folder
/// without touching the user's games.
public struct AppPaths: Sendable, Equatable {
    /// `~/Library/Application Support/EscApp`, or `ESCAPP_HOME`.
    public let root: URL
    /// Where installers put games. Wine sees it as drive `G:`.
    public let games: URL

    public init(root: URL, games: URL) {
        self.root = root
        self.games = games
    }

    /// The real locations for this user. `environment` is a parameter so tests don't depend on the host.
    public static func standard(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppPaths {
        if let override = environment["ESCAPP_HOME"], !override.isEmpty {
            let root = URL(filePath: override, directoryHint: .isDirectory)
            return AppPaths(root: root, games: root.appending(path: "Games", directoryHint: .isDirectory))
        }
        return AppPaths(
            root: home.appending(path: "Library/Application Support/EscApp", directoryHint: .isDirectory),
            games: home.appending(path: "Games", directoryHint: .isDirectory)
        )
    }

    /// One folder per runtime version: Wine, DXVK, DXMT and Wine Mono.
    public var runtimes: URL { folder("Runtime") }
    /// One untouched template bottle per runtime. Game bottles are APFS clones of it.
    public var templates: URL { folder("Templates") }
    /// One bottle per game, named by game id.
    public var bottles: URL { folder("Bottles") }
    /// AppData and Saved Games shared by every bottle, so saves survive a new bottle or runtime.
    public var profile: URL { folder("Profile") }
    public var logs: URL { folder("Logs") }
    /// Partial downloads, named by SHA-256 so an interrupted download resumes even if the URL changed.
    public var downloads: URL { folder("Downloads") }
    public var screenshots: URL { folder("Screenshots") }
    public var library: URL { root.appending(path: "Games.json", directoryHint: .notDirectory) }

    public func runtime(_ id: String) -> URL { runtimes.appending(path: id, directoryHint: .isDirectory) }
    public func template(forRuntime id: String) -> URL { templates.appending(path: id, directoryHint: .isDirectory) }
    public func bottle(forGame id: GameID) -> URL { bottles.appending(path: id.rawValue, directoryHint: .isDirectory) }
    public func logs(forGame id: GameID) -> URL { logs.appending(path: id.rawValue, directoryHint: .isDirectory) }

    private func folder(_ name: String) -> URL { root.appending(path: name, directoryHint: .isDirectory) }
}
