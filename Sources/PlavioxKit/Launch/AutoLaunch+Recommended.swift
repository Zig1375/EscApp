import Foundation

extension AutoLaunch {
    /// A launch that looks for the game's settings: on Auto graphics, with nothing known to work yet and more than
    /// one backend to try. The app hides the game's window meanwhile, since a failing attempt can flash it open
    /// and shut. A store game too: the player wants the first-launch screen whichever way the game was started,
    /// and its client is usually signed in already, having just been asked to play.
    static func isTuning(_ game: GameRecord, order: [GraphicsBackend], retrying: Bool) -> Bool {
        retrying && order.count > 1 && game.backend == nil && game.chosenBackend == nil
    }

    /// The backends this launch tries, in order.
    ///
    /// A game that has worked here keeps its backend: a game played for a while failed to start once, the launch
    /// went on to another backend, that one was remembered, and from then on the game didn't start at all.
    /// Looking again is the player's call ("Find Launch Settings Again"), or happens by itself after the exe
    /// changes (`forgetLaunchSettings`). A game module's `require` comes before that, since it usually answers
    /// "the game worked, then stopped"; its `prefer` comes after, so a new revision doesn't undo what works here.
    static func order(for game: GameRecord, override: GraphicsBackend?, info: ExecutableInfo?,
                      recommended: RecommendedSettings?, known: KnownGame?,
                      module: GameModules.Launch = GameModules.Launch(), d3dmetal: Bool = false) -> [GraphicsBackend] {
        if let only = override ?? game.chosenBackend ?? module.requireBackend ?? game.backend { return [only] }
        guard case let .attempts(plan)? = info.map({ BackendPlan.forTraits($0.traits, d3dmetal: d3dmetal) }) else {
            // Unsupported or unreadable: `prepare` throws the reason.
            return [.dxvk]
        }
        // D3DMetal named by the folder, the module or the database, but not added here: left out.
        let planned = BackendPlan.order(plan, remembered: nil, preferred: module.preferBackends,
                                        recommended: recommended?.graphicsBackend,
                                        known: known?.preferredBackend)
            .filter { d3dmetal || $0 != .d3dmetal }
        // A store game is searched for like any other: Among Us hung on DXVK, and the player had to find DXMT
        // in Advanced. Another backend restarts the store's client in its Wine tree (`prepareForGame`).
        return game.store == nil ? planned : storeOrder(planned, directX: info?.directX.max(), d3dmetal: d3dmetal)
    }

    /// A store game's order: everything in the bottle runs in one Wine tree, the client too. Steam's window
    /// doesn't start on plain Wine ("Failed creating offscreen shared JS context"), so it never started Among
    /// Us on WineD3D and the search waited for good; D3DMetal, which runs Direct3D 11 as well, takes its place.
    static func storeOrder(_ planned: [GraphicsBackend], directX: ExecutableTraits.DirectX?,
                           d3dmetal: Bool) -> [GraphicsBackend] {
        var order = planned.filter { $0 != .wined3d }
        if d3dmetal, directX == .d3d11 || directX == nil, !order.contains(.d3dmetal) { order.append(.d3dmetal) }
        return order.isEmpty ? planned : order
    }

    /// What the game database and the game's module know about the game. The Windows version they name is the
    /// first launch's; after that the player may have set one by hand.
    func knownSettings(for game: inout GameRecord, info: ExecutableInfo?,
                       context: Context) throws -> (KnownGame?, GameModules.Launch) {
        let known = KnownGame.find(in: context.knownGames, executable: URL(filePath: game.executable),
                                   productName: info?.productName)
        let module = (try? GameModules.resolve(game, info: info, runtime: context.runtime, modules: context.modules,
                                               app: GameModules.appVersion)?.launch.get()) ?? GameModules.Launch()
        if (game.launches ?? 0) == 0, let windows = module.requireWindows ?? module.preferWindows
            ?? known?.windowsVersion, windows != game.windowsVersion {
            game.windowsVersion = windows
            try update(game.id) { $0.windowsVersion = windows }
        }
        return (known, module)
    }

    /// The order once attempt `index` showed the program is Chromium: what was tried, then Chromium's own order.
    static func order(afterFindingChromiumIn order: [GraphicsBackend], tried index: Int) -> [GraphicsBackend] {
        Array(order.prefix(index + 1)) + BackendPlan.chromiumAttempts
    }

    /// The settings from the game's `.plaviox`, for its first attempt. Windows only as for the game database: once
    /// the game was launched here the player may have set it by hand.
    static func apply(_ recommended: RecommendedSettings, to game: inout GameRecord) {
        if (game.launches ?? 0) == 0, let windows = recommended.windowsVersion { game.windowsVersion = windows }
        if game.chromium == nil { game.chromium = recommended.chromiumMode }
    }

    /// Remembers what the game just worked with, here and in its `.plaviox` for whoever gets the folder next.
    func keep(_ game: GameRecord, workingWith backend: GraphicsBackend) throws {
        let (windows, chromium) = (game.windowsVersion, game.chromium)
        try update(game.id) { record in
            record.windowsVersion = windows
            if let chromium { record.chromium = chromium }
        }
        GameIdentifier.recommend(RecommendedSettings(backend: backend, windows: windows, chromium: chromium), for: game)
    }
}
