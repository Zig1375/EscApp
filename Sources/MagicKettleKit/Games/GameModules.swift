import Foundation

/// Finds a game's module in the index and turns it into launch settings (`docs/GAME-MODULES.md`): pure functions,
/// so what a module does to a launch is decided by tests, not by a running game.
public enum GameModules {
    /// What the game is, as far as matching and conditions need it.
    public struct Game: Sendable, Equatable {
        public var store: Store?
        public var storeID: String?
        public var executable: URL
        public var productName: String?

        public init(store: Store?, storeID: String?, executable: URL, productName: String?) {
            self.store = store
            self.storeID = storeID
            self.executable = executable
            self.productName = productName
        }

        public init(_ record: GameRecord, productName: String?) {
            self.init(store: record.store, storeID: record.storeID, executable: URL(filePath: record.executable),
                      productName: productName)
        }
    }

    /// The module for `game`, most reliable match first: its store and id there, the exe's SHA-256, its name with
    /// its ProductName, its name alone. Modules in a format this app doesn't know, or for a newer app, are skipped.
    /// - Parameter sha256: the exe's SHA-256, asked for only when a module matches by it.
    public static func find(for game: Game, in modules: [GameModule], app: Version?,
                            sha256: () -> String? = { nil }) -> GameModule? {
        let usable = modules.filter { module in
            guard module.format == GameModule.knownFormat else { return false }
            guard let app, let minApp = module.requires?.minApp.flatMap(Version.init) else { return true }
            return app >= minApp
        }
        if let store = game.store, let id = game.storeID,
           let found = usable.first(where: { storeIDs(of: $0, for: store).contains(id) }) {
            return found
        }
        let name = game.executable.lastPathComponent
        let exes = usable.flatMap { module in (module.match?.exe ?? []).map { (module, $0) } }
            .filter { $0.1.name.caseInsensitiveCompare(name) == .orderedSame }
        if exes.contains(where: { $0.1.sha256 != nil }), let hash = sha256()?.lowercased(),
           let found = exes.first(where: { $0.1.sha256?.contains(hash) == true }) {
            return found.0
        }
        let product = game.productName?.trimmingCharacters(in: .whitespaces)
        if let product, let found = exes.first(where: {
            $0.1.sha256 == nil && $0.1.product?.caseInsensitiveCompare(product) == .orderedSame
        }) {
            return found.0
        }
        return exes.first { $0.1.sha256 == nil && $0.1.product == nil }?.0
    }

    static func storeIDs(of module: GameModule, for store: Store) -> [String] {
        switch store {
        case .steam: module.match?.steam ?? []
        case .epic: module.match?.epic ?? []
        default: []
        }
    }

    /// What a module asks of a launch, after its conditions.
    public struct Launch: Sendable, Equatable {
        /// The first attempts, in order.
        public var preferBackends: [GraphicsBackend] = []
        /// Fixed: this backend only, like a choice in Advanced.
        public var requireBackend: GraphicsBackend?
        public var preferWindows: WindowsVersion?
        public var requireWindows: WindowsVersion?

        public init() {}

        public var isEmpty: Bool { self == Launch() }
    }

    /// Why a module found for a game isn't applied, for the launch log.
    public enum Skip: Error, Equatable {
        /// `requires.wine` names a newer (or older) Wine than the installed one.
        case wine(installed: Version)
    }

    /// The launch settings of `module` for a game on Wine `wine`. Groups apply in order and a later one overrides
    /// an earlier one. A group whose condition can't be decided before the launch (its backend, its Steam build,
    /// its exe's SHA-256 when that wasn't given) is left out: wrongly applied is worse than not applied.
    public static func launch(of module: GameModule, store: Store?, wine: Version,
                              exeSha256: String? = nil) throws(Skip) -> Launch {
        if let range = module.requires?.wine, !range.contains(wine) { throw .wine(installed: wine) }
        var result = Launch()
        for group in module.fixes where holds(group.when, store: store, wine: wine, exeSha256: exeSha256) {
            guard let launch = group.launch else { continue }
            if let backends = launch.prefer?.backend?.compactMap(GraphicsBackend.init(rawValue:)), !backends.isEmpty {
                result.preferBackends = backends
            }
            if let backend = launch.require?.backend?.first.flatMap(GraphicsBackend.init(rawValue:)) {
                result.requireBackend = backend
            }
            if let windows = launch.prefer?.windows.flatMap(WindowsVersion.init(wineValue:)) {
                result.preferWindows = windows
            }
            if let windows = launch.require?.windows.flatMap(WindowsVersion.init(wineValue:)) {
                result.requireWindows = windows
            }
        }
        return result
    }

    static func holds(_ when: GameModule.When?, store: Store?, wine: Version, exeSha256: String?) -> Bool {
        guard let when else { return true }
        if when.backend != nil || when.steamBuild != nil { return false }
        if let range = when.wine, !range.contains(wine) { return false }
        if let stores = when.store, !stores.contains(store?.rawValue ?? "none") { return false }
        if let hashes = when.exeSha256 {
            guard let exeSha256, hashes.contains(exeSha256.lowercased()) else { return false }
        }
        return true
    }

    /// This app's version for `requires.minApp`; nil (the CLI, tests) applies modules whatever they require.
    public static var appVersion: Version? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(Version.init)
    }

    /// The Wine version of a runtime, from its Wine component ("11.20 (Magic Kettle build 9)" → 11.20).
    public static func wineVersion(of runtime: RuntimeManifest.Runtime) -> Version {
        let wine = runtime.components.first { $0.kind == .wine }?.version ?? ""
        return wine.split(separator: " ").first.flatMap { Version(String($0)) } ?? .zero
    }

    /// The module and its settings for a launch, or why there are none; nil when no module knows the game.
    public static func resolve(_ record: GameRecord, info: ExecutableInfo?, runtime: RuntimeManifest.Runtime,
                               modules: [GameModule], app: Version?)
        -> (module: GameModule, launch: Result<Launch, Skip>)? {
        let game = Game(record, productName: info?.productName)
        let exe = game.executable
        var hash: String?
        let sha256 = {
            if hash == nil { hash = try? Downloader.sha256(of: exe) }
            return hash
        }
        guard let module = find(for: game, in: modules, app: app, sha256: sha256) else { return nil }
        let needsHash = module.fixes.contains { $0.when?.exeSha256 != nil }
        let wine = wineVersion(of: runtime)
        do {
            let launch = try launch(of: module, store: record.store, wine: wine,
                                    exeSha256: needsHash ? sha256() : nil)
            return (module, .success(launch))
        } catch {
            return (module, .failure(error))
        }
    }
}
