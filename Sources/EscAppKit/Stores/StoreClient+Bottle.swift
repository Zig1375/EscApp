import Foundation

/// What EscApp writes into a store's bottle before its client starts.
extension StoreClient {
    /// Store clients draw at the screen's full resolution. At Wine's default, Steam's windows were drawn at half
    /// the pixels and stretched by macOS: soft text with coloured ClearType fringes, jagged corners. The DPI
    /// matches, so they keep their size: clients that handle high DPI (Steam, Epic) draw larger themselves, and
    /// Wine enlarges the ones that don't. A store game started while its client is idle gets its own settings
    /// (`GameLauncher.configure`). Only while the bottle's Wine is down.
    static func drawSharp(_ bottle: URL, scale: Double = GameScaling.backingScale()) throws {
        let retina = scale > 1
        try BottleManager.setRegistryString(bottle: bottle, key: #"Software\Wine\Mac Driver"#, name: "RetinaMode",
                                            value: retina ? "y" : "n")
        try BottleManager.setRegistryDWord(bottle: bottle, key: #"Control Panel\Desktop"#, name: "LogPixels",
                                           value: UInt32(GameScaling.dpi(for: retina ? scale : 1)))
    }

    /// What every game gets from `GameLauncher.configure`, written while the client is down: the client stays up
    /// while its games run, so a store game's own launch finds the bottle busy and can't write it. Without it
    /// Banished, started from Steam, switched the Mac's display to 960×600 and the mouse missed its buttons.
    static func setUpForGames(_ bottle: URL) throws {
        try BottleManager.disableCrashDialog(bottle: bottle)
        try BottleManager.enableScaling(bottle: bottle)
    }

    /// Whether the bottle's Wine draws in Retina mode, as written before its client started (`drawSharp`).
    static func runsRetina(_ bottle: URL) -> Bool {
        let text = try? String(contentsOf: bottle.appending(path: "user.reg"), encoding: .utf8)
        let key = #"Software\Wine\Mac Driver"#
        return text.flatMap { WineRegistry.string(in: $0, key: key, name: "RetinaMode") } == "y"
    }
}

extension StoreClient {
    /// A store client opened like a game, in a bottle of its own: what Stores does for it happens there too. What
    /// its store needs for a client the player installed comes first (Steam downloads its client, whose web
    /// helper would otherwise run unwrapped, black, the first time), then its Chromium helpers are wrapped. Only
    /// while nothing runs in the bottle.
    func prepareClientProgram(_ store: Store, in bottle: URL, wine: Wine) async throws {
        guard WineProcesses.running(in: bottle).isEmpty else { return }
        if let client = store.client(in: bottle) {
            try await store.module.prepareInstalledByPlayer(self, client: client, bottle: bottle, wine: wine)
        }
        try ChromiumHelper.wrap(store, in: bottle)
    }
}
