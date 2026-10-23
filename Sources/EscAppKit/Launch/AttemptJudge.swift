import Foundation

/// Decides, while a game starts, whether this attempt works with its backend (the first-run check in
/// ARCHITECTURE.md). Fed what the launch loop sees every few hundred milliseconds; pure, so the rules are tested
/// without Wine.
public struct AttemptJudge: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// The game's window has stayed up long enough.
        case working
        /// Everything in the bottle ended without an error code: a short program, or a quick clean quit. Whether
        /// it worked is up to the log.
        case ended
        case failed(Failure)
    }

    public enum Failure: Sendable, Equatable {
        /// The game's process ended with an error code before it counted as working.
        case closed(exitCode: Int32)
        /// No window appeared in time.
        case noWindow
    }

    /// How long the window has to stay up. A crash later than this is the game's, not the backend's.
    public static let windowHolds: TimeInterval = 15
    /// How long a first launch may take to show a window. Wine's first start under Rosetta takes up to ~20 s.
    public static let firstWindowTimeout: TimeInterval = 60

    /// Nil: never give up waiting for a window (a backend that already worked for this game).
    let windowTimeout: TimeInterval?
    let windowHolds: TimeInterval
    private(set) var windowSince: TimeInterval?

    public init(windowTimeout: TimeInterval?, windowHolds: TimeInterval = Self.windowHolds) {
        self.windowTimeout = windowTimeout
        self.windowHolds = windowHolds
    }

    public var sawWindow: Bool { windowSince != nil }

    /// - Parameters:
    ///   - elapsed: seconds since the game's process started.
    ///   - window: whether a window of the game is on screen now.
    ///   - exitCode: the game's process's exit code, once it exited. A launcher may exit 0 and leave the game
    ///     running, so 0 alone decides nothing.
    ///   - idle: whether everything in the bottle has stopped.
    public mutating func observe(elapsed: TimeInterval, window: Bool, exitCode: Int32?, idle: Bool) -> Verdict? {
        if window, windowSince == nil { windowSince = elapsed }
        if let exitCode, exitCode != 0 { return .failed(.closed(exitCode: exitCode)) }
        if let windowSince, elapsed - windowSince >= windowHolds { return .working }
        if idle { return .ended }
        if windowSince == nil, let windowTimeout, elapsed >= windowTimeout { return .failed(.noWindow) }
        return nil
    }
}
