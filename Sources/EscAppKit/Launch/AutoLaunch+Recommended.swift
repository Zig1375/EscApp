import Foundation

extension AutoLaunch {
    /// The backends this launch tries, in order.
    ///
    /// A game that has worked here keeps its backend: a game played for a while failed to start once, the launch
    /// went on to another backend, that one was remembered, and from then on the game didn't start at all.
    /// Looking again is the player's call ("Find Launch Settings Again"), or happens by itself after the exe
    /// changes (`forgetLaunchSettings`). A game module's `require` comes before that, since it usually answers
    /// "the game worked, then stopped"; its `prefer` comes after, so a new revision doesn't undo what works here.
    static func order(for game: GameRecord, override: GraphicsBackend?, info: ExecutableInfo?,
                      recommended: RecommendedSettings?, known: KnownGame?,
                      module: GameModules.Launch = GameModules.Launch()) -> [GraphicsBackend] {
        if let only = override ?? game.chosenBackend ?? module.requireBackend ?? game.backend { return [only] }
        guard case let .attempts(plan)? = info.map({ BackendPlan.forTraits($0.traits) }) else {
            // Unsupported or unreadable: `prepare` throws the reason.
            return [.dxvk]
        }
        let planned = BackendPlan.order(plan, remembered: nil, preferred: module.preferBackends,
                                        recommended: recommended?.graphicsBackend,
                                        known: known?.preferredBackend)
        // A store game gets one try: another backend means restarting the store's client, and its first start
        // may sit behind the store's sign-in or an update for as long as those take.
        return game.store == nil ? planned : Array(planned.prefix(1))
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

    /// The settings from the game's `.escapp`, for its first attempt. Windows only as for the game database: once
    /// the game was launched here the player may have set it by hand.
    static func apply(_ recommended: RecommendedSettings, to game: inout GameRecord) {
        if (game.launches ?? 0) == 0, let windows = recommended.windowsVersion { game.windowsVersion = windows }
        if game.chromium == nil { game.chromium = recommended.chromiumMode }
    }

    /// Remembers what the game just worked with, here and in its `.escapp` for whoever gets the folder next.
    func keep(_ game: GameRecord, workingWith backend: GraphicsBackend) throws {
        let (windows, chromium) = (game.windowsVersion, game.chromium)
        try update(game.id) { record in
            record.windowsVersion = windows
            if let chromium { record.chromium = chromium }
        }
        GameIdentifier.recommend(RecommendedSettings(backend: backend, windows: windows, chromium: chromium), for: game)
    }
}
