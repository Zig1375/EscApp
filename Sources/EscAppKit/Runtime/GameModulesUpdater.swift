import Foundation

/// Keeps the game modules current, as `ManifestUpdater` does the component list: the app's own copy works offline
/// and on a new Mac, and the index EscApp-Games' CI builds on `main` is fetched about once a day into
/// `EscApp/GameModules.json`. The whole index is fetched and games are matched on the Mac, so nobody learns which
/// games a player has.
///
/// A module only names settings EscApp applies from a closed list; it brings nothing that runs.
public struct GameModulesUpdater: Sendable {
    static let indexPath = "Zig1375/EscApp-Games/main/games.json"
    // A constant, well-formed URL; failing here would be a typo caught by the first test run.
    // swiftlint:disable:next force_unwrapping
    public static let defaultURL = URL(string: "https://raw.githubusercontent.com/\(indexPath)")!

    /// What was last fetched, and when.
    public struct Cache: Codable, Sendable, Equatable {
        public var checkedAt: Date
        public var index: GameModuleIndex
    }

    let paths: AppPaths
    let url: URL
    let configuration: URLSessionConfiguration
    let bundled: @Sendable () throws -> GameModuleIndex

    public init(
        paths: AppPaths,
        url: URL = GameModulesUpdater.defaultURL,
        configuration: URLSessionConfiguration = .ephemeral,
        bundled: @escaping @Sendable () throws -> GameModuleIndex = { try GameModuleIndex.bundled() }
    ) {
        self.paths = paths
        self.url = url
        self.configuration = configuration
        self.bundled = bundled
    }

    public var cacheFile: URL { paths.gameModules }

    public func cached() -> Cache? {
        guard let data = try? Data(contentsOf: cacheFile),
              let cache = try? JSONDecoder.iso.decode(Cache.self, from: data),
              cache.index.format == GameModule.knownFormat
        else { return nil }
        return cache
    }

    /// The modules to use right now, without touching the network. Never fails: without an index there are
    /// simply no modules, and games launch by the general rules.
    public func current() -> GameModuleIndex {
        Self.choose(bundled: try? bundled(), cached: cached()?.index)
            ?? GameModuleIndex(modules: [])
    }

    /// The newer index wins: the app's copy after an app update that came with newer modules than last day's
    /// download, the download otherwise.
    static func choose(bundled: GameModuleIndex?, cached: GameModuleIndex?) -> GameModuleIndex? {
        guard let cached else { return bundled }
        guard let bundled else { return cached }
        return (bundled.generated ?? .distantPast) > (cached.generated ?? .distantPast) ? bundled : cached
    }

    public static func isDue(lastChecked: Date?, now: Date = Date()) -> Bool {
        ManifestUpdater.isDue(lastChecked: lastChecked, now: now)
    }

    /// Fetches the index and caches it. Returns the index to use from now on.
    @discardableResult
    public func check(now: Date = Date()) async throws -> GameModuleIndex {
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw DownloadError.httpStatus(status)
        }
        let index = try GameModuleIndex.decode(data)
        // A newer format is for a newer app: keep what we have.
        guard index.format == GameModule.knownFormat else { return current() }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try JSONEncoder.iso.encode(Cache(checkedAt: now, index: index)).write(to: cacheFile, options: .atomic)
        return current()
    }
}
