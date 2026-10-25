import CoreGraphics

/// Enlarging old games that run in a small window or a low-resolution full screen, without switching the Mac's
/// display. Wine does the drawing, these rules decide when and how much:
///
/// - **Full screen.** A game asking for 640×480 used to fail outright: Wine looked for that mode on the Mac's
///   display, found none and refused (Direct3D 9 couldn't even create its device). With `EmulateModeset` Wine
///   tells the game the display is now 640×480, leaves the Mac's display alone, and fits the game's window to the
///   whole screen, keeping its proportions. EscApp turns that on for every game.
/// - **A small window.** Wine draws a DPI-unaware program larger when the system DPI is above 96, as Windows does
///   on a high-DPI screen, and maps the mouse back. EscApp sets the DPI from the size the game's window had last
///   time (`LearnedWindow`): the DPI must be set before a launch. Before the first run the size is known only for
///   games that say it in their files (RPG Maker, `RGSSArchive`); others start at their own size once.
///   Games that declare high-DPI support draw for Retina themselves and are left alone.
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

    /// What EscApp saw of the game's window on its last run, in the game's own pixels.
    public struct LearnedWindow: Codable, Sendable, Equatable {
        public var width: Int
        public var height: Int
        /// It covered the whole screen: a full-screen game, which Wine fits to the screen by itself.
        public var fullScreen: Bool

        public init(width: Int, height: Int, fullScreen: Bool) {
            self.width = width
            self.height = height
            self.fullScreen = fullScreen
        }
    }

    public static let standardDPI = 96

    /// The system DPI at which Wine draws a DPI-unaware game `scale` times larger.
    public static func dpi(for scale: Double) -> Int { Int((Double(standardDPI) * scale).rounded()) }

    /// How much larger to draw the game on this launch; 1 when it is shown as it is.
    public static func scale(setting: Setting, learned: LearnedWindow?, dpiAware: Bool, screen: Size) -> Double {
        guard !dpiAware, let learned, !learned.fullScreen else { return 1 }
        let window = Window(size: Size(width: learned.width, height: learned.height), canGrowByItself: false)
        return decide(setting: setting, window: window, screen: screen)?.scale ?? 1
    }

    /// The game's window from its frame on the Mac, in points, which are the game's pixels while Retina is off;
    /// `scale` undoes the enlarging it ran with.
    public static func learn(frame: CGRect, display: CGRect, scale: Double) -> LearnedWindow {
        // A full-screen window covers the display, menu bar included; allow for rounding.
        let fullScreen = frame.width >= display.width - 2 && frame.height >= display.height - 2
        return LearnedWindow(width: Int((frame.width / scale).rounded()), height: Int((frame.height / scale).rounded()),
                             fullScreen: fullScreen)
    }

    /// Pixels per point of the main display: 2 on Retina. With Retina on, the game's pixels are these.
    public static func backingScale() -> Double {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()), mode.width > 0 else { return 1 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    /// The room a game window has on the main display, in points: less the menu bar and the window's title bar.
    public static func availableScreen(display: CGRect = CGDisplayBounds(CGMainDisplayID())) -> Size {
        Size(width: Int(display.width), height: max(Int(display.height) - 33 - 28, 1))
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
