import Foundation

extension GameLauncher {
    /// How many times larger Wine will draw the game on this launch, and the system DPI that does it
    /// (`GameScaling`): what `configure` writes into the bottle, and what a client that keeps the bottle is
    /// measured against (`StoreClient.prepareForGame`).
    /// - Parameter predicted: the game's window known before it ever ran (`GameFiles.window`); what was seen on a
    ///   launch wins over it.
    static func drawing(for game: GameRecord, retina: Bool, predicted: GameScaling.LearnedWindow? = nil,
                        screen: GameScaling.Size = GameScaling.availableScreen()) -> (scale: Double, dpi: Int) {
        let scale = GameScaling.scale(setting: game.scaling ?? .auto, learned: game.window ?? predicted,
                                      dpiAware: retina, screen: screen)
        return (scale, GameScaling.dpi(for: scale))
    }
}
