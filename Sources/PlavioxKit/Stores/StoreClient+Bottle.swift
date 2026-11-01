import Foundation

/// What Plaviox writes into a store's bottle before its client starts.
extension StoreClient {
    /// Store clients draw at the screen's full resolution. At Wine's default, Steam's windows were drawn at half
    /// the pixels and stretched by macOS: soft text with coloured ClearType fringes, jagged corners. The DPI
    /// matches, so they keep their size: clients that handle high DPI (Epic) draw larger themselves, and Wine
    /// enlarges the ones that don't. A store game started while its client is idle gets its own settings
    /// (`GameLauncher.configure`). Only while the bottle's Wine is down.
    /// - Parameter retina: false for a client whose own windows are drawn at a fixed pixel size, which Retina
    ///   mode leaves at half the size of the rest of its interface (`StoreModule.drawsAtScreenResolution`).
    static func drawSharp(_ bottle: URL, scale: Double = GameScaling.backingScale(), retina: Bool = true) throws {
        let retina = retina && scale > 1
        try BottleManager.setRegistryString(bottle: bottle, key: BottleManager.macDriverKey, name: "RetinaMode",
                                            value: retina ? "y" : "n")
        try BottleManager.setRegistryDWord(bottle: bottle, key: BottleManager.desktopKey, name: "LogPixels",
                                           value: UInt32(GameScaling.dpi(for: retina ? scale : 1)))
    }

    /// What every game gets from `GameLauncher.configure`, written while the client is down: the client stays up
    /// while its games run, so a store game's own launch finds the bottle busy and can't write it. Without it
    /// Banished, started from Steam, switched the Mac's display to 960×600 and the mouse missed its buttons.
    static func setUpForGames(_ bottle: URL) throws {
        try BottleManager.disableCrashDialog(bottle: bottle)
        try BottleManager.enableScaling(bottle: bottle)
        // Every game's default (`GameRecord.commandAsControl`); it also lets ⌘V paste into the client's own
        // sign-in fields.
        try BottleManager.setCommandAsControl(bottle: bottle, true)
    }

    /// What a bottle's Wine draws with, as it was written before the running Wine started: `drawSharp` for a
    /// client, `GameLauncher.configure` for a game.
    struct Drawn: Equatable, Sendable {
        /// Retina mode: the screen's full resolution, with the DPI to match.
        var retina: Bool
        /// `LogPixels`: the system DPI Wine draws a DPI-unaware program with.
        var dpi: Int
    }

    /// What the bottle's Wine draws with now; Wine's own defaults, no Retina mode and 96 DPI, when nothing wrote
    /// them there.
    static func drawn(_ bottle: URL) -> Drawn {
        let text = try? String(contentsOf: bottle.appending(path: "user.reg"), encoding: .utf8)
        let retina = text.flatMap { WineRegistry.string(in: $0, key: BottleManager.macDriverKey, name: "RetinaMode") }
        let dpi = text.flatMap { WineRegistry.dword(in: $0, key: BottleManager.desktopKey, name: "LogPixels") }
        return Drawn(retina: retina == "y", dpi: dpi.map(Int.init) ?? GameScaling.standardDPI)
    }

    /// Whether a game of `store` gets Wine's Retina mode. Retina belongs to the whole bottle rather than to one
    /// program, and the client runs in that bottle too: a client whose own windows are drawn at a fixed pixel size
    /// (Steam) can't be in Retina mode, so its games run without it — softer, at the size they should be. A game
    /// started while such a client already runs keeps its settings (`needsRestart`); this is the same rule for a
    /// client this launch starts itself. Among Us started from Plaviox with Steam closed had Retina written into the
    /// bottle before Steam started in it, and Steam's own window came out at half its size and stayed that way.
    public static func retina(_ wanted: Bool, for store: Store?) -> Bool {
        wanted && (store?.drawsAtScreenResolution ?? true)
    }

    /// Whether a game would be drawn worse than it asks for while the client keeps the bottle as it is. Wine
    /// halves the mouse position for a program that doesn't handle high DPI when the client runs in Retina mode:
    /// none of Banished's buttons could be clicked. A game's small window is enlarged only by a higher system
    /// DPI, and the DPI has to be written before its Wine starts. Retina for a game that does handle high DPI,
    /// when the client doesn't run in it, only draws softer, which isn't worth restarting the client for.
    static func needsRestart(drawn: Drawn, wanted: Drawn) -> Bool {
        if drawn.retina != wanted.retina { return drawn.retina }
        return wanted.dpi > drawn.dpi
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
