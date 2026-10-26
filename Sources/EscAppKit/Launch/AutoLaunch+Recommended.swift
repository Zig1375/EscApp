import Foundation

extension AutoLaunch {
    /// The backends this launch tries, in order.
    static func order(for game: GameRecord, override: GraphicsBackend?, info: ExecutableInfo?,
                      recommended: RecommendedSettings?, known: KnownGame?) -> [GraphicsBackend] {
        if let override = override ?? game.chosenBackend { return [override] }
        guard case let .attempts(plan)? = info.map({ BackendPlan.forTraits($0.traits) }) else {
            // Unsupported or unreadable: `prepare` throws the reason.
            return [game.backend ?? .dxvk]
        }
        let planned = BackendPlan.order(plan, remembered: game.backend, recommended: recommended?.graphicsBackend,
                                        known: known?.preferredBackend)
        // A store game gets one try: another backend means restarting the store's client, and its first start
        // may sit behind the store's sign-in or an update for as long as those take.
        return game.store == nil ? planned : Array(planned.prefix(1))
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
