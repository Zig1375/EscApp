import Foundation

/// Store games the player started from the store's own window ("Play" in Steam) rather than from Plaviox. Among
/// Us started that way ran without the launch sheet and showed as not running in the library: Plaviox only knew
/// the games it started itself.
///
/// Such a game is either taken over as it runs (`adopt`: it shows as playing and its time counts), or, when the
/// launch Plaviox would have made differs from it, closed at once and started again the way Plaviox starts it
/// (`prepare`): a game whose settings Plaviox hasn't found yet (never started through it, or "Find Launch Settings
/// Again"), or one that its client's bottle would draw worse than it asks for (`StoreClient.needsRestart`).
public enum StoreGameStarts {
    public enum Verdict: Equatable, Sendable {
        case adopt
        case prepare
    }

    /// A game found running in its store's bottle.
    public struct Found: Sendable {
        public var game: GameRecord
        public var verdict: Verdict
        /// What the library needs to show, bring forward and stop the game.
        public var session: GameSession
        /// When its first process started.
        public var since: Date
    }

    /// Only a game that has just started is closed to start it again: one found older (Plaviox opened while it
    /// ran) is taken over, rather than ended in the middle of play.
    static let preparesWithin: TimeInterval = 30

    /// The pure decision for one game.
    /// - Parameters:
    ///   - settled: the game was started through Plaviox and has a backend that works, found or chosen. Among Us,
    ///     launched once and then sent to "Find Launch Settings Again", was taken over as it ran on DXVK's black
    ///     window instead of being searched for.
    ///   - age: how long its first process has run.
    ///   - drawn: what the client's bottle draws with, and what the game asks for (`StoreClient.needsRestart`).
    static func verdict(settled: Bool, age: TimeInterval, running: GraphicsBackend?, wanted: GraphicsBackend?,
                        drawn: (runs: StoreClient.Drawn, wanted: StoreClient.Drawn)) -> Verdict {
        guard age < preparesWithin else { return .adopt }
        if !settled { return .prepare }
        if let wanted, running != wanted { return .prepare }
        return StoreClient.needsRestart(drawn: drawn.runs, wanted: drawn.wanted) ? .prepare : .adopt
    }

    /// The store games running in their bottles that aren't in `skipping` (the games Plaviox started or already
    /// follows).
    public static func find(in games: [GameRecord], skipping: Set<GameID>, paths: AppPaths,
                            runtime: RuntimeManifest.Runtime?, now: Date = Date()) -> [Found] {
        let client = StoreClient(paths: paths)
        var found: [Found] = []
        for store in Store.allCases {
            let candidates = games.filter { $0.store == store && !skipping.contains($0.id) }
            guard !candidates.isEmpty else { continue }
            let bottle = client.bottle(for: store)
            let processes = WineProcesses.running(in: bottle)
            guard !processes.isEmpty, let wine = client.runningWine(store) else { continue }
            for game in candidates {
                let folder = WindowsPath.windowsPath(of: URL(filePath: game.folder, directoryHint: .isDirectory),
                                                     inBottle: bottle)
                let own = processes.filter { WineProcesses.runs($0.program, from: folder) }
                guard let first = own.first else { continue }
                let since = own.compactMap(\.started).min() ?? now
                let info = try? ExecutableInfo.read(URL(filePath: game.executable))
                let wanted = runtime.flatMap { runtime in
                    info.flatMap { try? GameLauncher(paths: paths).backend(for: game, info: $0, runtime: runtime,
                                                                         override: nil) }
                }
                let settled = (game.launches ?? 0) > 0 && (game.backend ?? game.chosenBackend) != nil
                let drawn = StoreClient.drawn(bottle)
                let gameRetina = GameSettings.retina(game.retina, dpiAware: info?.dpiAware ?? false)
                let wantsRetina = StoreClient.retina(gameRetina, for: game.store)
                let (_, dpi) = GameLauncher.drawing(for: game, retina: wantsRetina)
                let verdict = verdict(settled: settled, age: now.timeIntervalSince(since),
                                      running: BackendTree.backend(of: wine.root), wanted: wanted,
                                      drawn: (drawn, StoreClient.Drawn(retina: wantsRetina, dpi: dpi)))
                let environment = WineEnvironment.make(host: [:], bottle: bottle.path,
                                                       fastSync: WineEnvironment.fastSync(for: nil, wine: wine))
                let session = GameSession(wine: wine, environment: environment, processID: first.pid,
                                          scale: drawn.retina ? 1 / GameScaling.backingScale() : 1,
                                          gameFolder: folder)
                found.append(Found(game: game, verdict: verdict, session: session, since: since))
            }
        }
        return found
    }

    /// How long an adopted game is watched for freezing (`freezes`), like a first launch after its check.
    static let freezeWatch: TimeInterval = 180

    /// Whether an adopted game freezes on a blank window (`FrozenWindow`) in its first minutes. False once it
    /// ends, or the time is up. Among Us, remembered on DXVK by a check that missed its freeze, was started from
    /// Steam and taken over as it hung on black: such a game is closed and searched for again.
    /// - Parameter timing: how long a frozen window holds, as in a first launch (`AutoLaunch.Timing.frozenFor`).
    public static func freezes(_ found: Found, timing: AutoLaunch.Timing = .standard) async -> Bool {
        guard let folder = found.session.gameFolder,
              let prefix = found.session.environment["WINEPREFIX"] else { return false }
        let bottle = URL(filePath: prefix, directoryHint: .isDirectory)
        var frozen = FrozenWindow(holds: timing.frozenFor)
        let start = Date()
        while Date().timeIntervalSince(start) < freezeWatch,
              !WineProcesses.game(in: bottle, folder: folder).isEmpty {
            let owners = GameWindows.owners(of: found.session)
            // Without the Screen Recording permission, a window filling the screen stands in for a blank one.
            let blank = await WindowPicture.look(windowOf: owners)?.nearlyBlank ?? GameWindows.fillsScreen(owners)
            if !owners.isEmpty, frozen.observe(blank: blank, cpu: WineProcesses.cpuSeconds(of: owners),
                                               owners: owners, at: Date().timeIntervalSince(start)) {
                return true
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    /// Waits until an adopted game is over, the way a game Plaviox started through its store is followed
    /// (`StoreGameWatch`), and records the time played.
    public static func follow(_ found: Found, paths: AppPaths) async {
        guard let folder = found.session.gameFolder,
              let prefix = found.session.environment["WINEPREFIX"] else { return }
        // Already running: there is no starter to fail before the game appears.
        let starter = ProcessExit()
        starter.exited(0)
        let end = ProcessExit()
        StoreGameWatch(bottle: URL(filePath: prefix, directoryHint: .isDirectory), folder: folder,
                       steamApp: found.game.store == .steam ? found.game.storeID : nil)
            .watch(starter: starter, game: end)
        _ = await end.wait()
        try? GameLibrary.modify(paths.library) {
            $0.recordPlay(of: found.game.id, duration: Date().timeIntervalSince(found.since), working: nil)
        }
    }
}

extension BackendTree {
    /// The backend a Wine tree was built for: its marker says, and plain Wine (no marker) is WineD3D.
    static func backend(of tree: URL) -> GraphicsBackend {
        let marker = (try? Data(contentsOf: tree.appending(path: markerName)))
            .flatMap { try? JSONDecoder().decode(Marker.self, from: $0) }
        return marker?.backend ?? .wined3d
    }
}
