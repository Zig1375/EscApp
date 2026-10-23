/// EscApp's own upscaling of a game window: it captures the game's frames and draws them larger, so it works for
/// games that refuse to resize. These rules decide when that happens and how it looks.
public enum GameScaling {
    public enum Setting: String, CaseIterable, Codable, Sendable {
        case auto, on, off
    }

    public enum Filter: String, Codable, Sendable, Equatable {
        /// Whole multiples, nearest pixel. Pixel art stays sharp instead of turning to mush.
        case sharpPixels
        /// Smooth scaling to fill the space, for games with detailed art or odd sizes.
        case smooth
    }

    public struct Size: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public struct Window: Sendable, Equatable {
        public var size: Size
        /// The game lets the user resize its window or switch to full screen, so it can grow without help.
        public var canGrowByItself: Bool
        public init(size: Size, canGrowByItself: Bool) {
            self.size = size
            self.canGrowByItself = canGrowByItself
        }
    }

    public struct Decision: Sendable, Equatable {
        public var filter: Filter
        /// How many times larger the game is drawn. A whole number for `sharpPixels`.
        public var scale: Double
        public init(filter: Filter, scale: Double) {
            self.filter = filter
            self.scale = scale
        }
    }

    /// - Parameters:
    ///   - screen: the visible area the game can fill, in the same pixels the game renders in.
    ///   - latencySensitive: from the game database. Scaling costs about a frame, which fast shooters notice.
    /// - Returns: `nil` when the game is shown as it is.
    public static func decide(
        setting: Setting,
        window: Window,
        screen: Size,
        latencySensitive: Bool = false
    ) -> Decision? {
        let fit = min(Double(screen.width) / Double(window.size.width),
                      Double(screen.height) / Double(window.size.height))
        // Nothing to gain if the game already fills the screen.
        guard fit > 1 else { return nil }
        switch setting {
        case .off:
            return nil
        case .auto:
            guard !latencySensitive, !window.canGrowByItself, window.size.height * 2 <= screen.height else {
                return nil
            }
        case .on:
            break
        }
        let filter: Filter = window.size.width <= 800 && window.size.height <= 600 ? .sharpPixels : .smooth
        let scale = filter == .sharpPixels ? fit.rounded(.down) : fit
        return Decision(filter: filter, scale: scale)
    }
}
