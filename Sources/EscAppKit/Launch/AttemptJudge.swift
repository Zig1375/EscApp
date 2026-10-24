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
        /// The window stayed one flat colour the whole time it was checked (`WindowPicture`).
        case blankPicture
    }

    /// How long the window has to stay up. A crash later than this is the game's, not the backend's.
    public static let windowHolds: TimeInterval = 15
    /// How long a first launch may take to show a window. Wine's first start under Rosetta takes up to ~20 s.
    public static let firstWindowTimeout: TimeInterval = 60

    /// Nil: never give up waiting for a window (a backend that already worked for this game).
    let windowTimeout: TimeInterval?
    let windowHolds: TimeInterval
    private(set) var windowSince: TimeInterval?
    /// Whether to fail a window that only ever showed a flat colour: for Chromium programs, whose blank window
    /// says the picture is lost. Other games may sit on a black loading screen for longer than the check.
    var checksPicture = false
    private(set) var blankSamples = 0
    private(set) var sawPicture = false
    /// Looks needed before a window counts as blank.
    static let blankSamplesNeeded = 4
    /// How long a Chromium window may stay blank before that counts: a cold start under Wine draws Electron's
    /// first page after about 20 s.
    static let blankPatience: TimeInterval = 40
    /// Scaled with `windowHolds`, so tests with short holds stay short.
    var blankAfter: TimeInterval { max(windowHolds, Self.blankPatience * windowHolds / Self.windowHolds) }

    public init(windowTimeout: TimeInterval?, windowHolds: TimeInterval = Self.windowHolds) {
        self.windowTimeout = windowTimeout
        self.windowHolds = windowHolds
    }

    public var sawWindow: Bool { windowSince != nil }

    /// How long the window has been up at `elapsed`; nil before it appeared.
    public func held(at elapsed: TimeInterval) -> TimeInterval? {
        windowSince.map { max(elapsed - $0, 0) }
    }

    /// - Parameters:
    ///   - elapsed: seconds since the game's process started.
    ///   - window: whether a window of the game is on screen now.
    ///   - exitCode: the game's process's exit code, once it exited. A launcher may exit 0 and leave the game
    ///     running, so 0 alone decides nothing.
    ///   - idle: whether everything in the bottle has stopped.
    /// - Parameter blank: what a look at the window showed now: flat (true), a picture (false), or nothing.
    public mutating func observe(elapsed: TimeInterval, window: Bool, exitCode: Int32?, idle: Bool,
                                 blank: Bool? = nil) -> Verdict? {
        if window, windowSince == nil { windowSince = elapsed }
        if window, let blank {
            if blank { blankSamples += 1 } else { sawPicture = true }
        }
        if let exitCode, exitCode != 0 { return .failed(.closed(exitCode: exitCode)) }
        if let windowSince, elapsed - windowSince >= windowHolds {
            // A Chromium window that hasn't drawn yet gets longer; one that has works.
            guard checksPicture, !sawPicture else { return .working }
            if elapsed - windowSince >= blankAfter {
                return blankSamples >= Self.blankSamplesNeeded ? .failed(.blankPicture) : .working
            }
        }
        if idle { return .ended }
        if windowSince == nil, let windowTimeout, elapsed >= windowTimeout { return .failed(.noWindow) }
        return nil
    }
}

/// After a first launch counted as working: a window that appears later (the game's own after its launcher's, or
/// Steam's sign-in after its updater) and stays one flat colour as long as `AttemptJudge.blankAfter` without ever
/// drawing. A window that drew once and then went black is the game's own (a loading screen) and isn't counted.
struct LateBlank: Sendable, Equatable {
    let patience: TimeInterval
    private var window: UInt32?
    private var since: TimeInterval?
    private var looks = 0
    private var drawn: Set<UInt32> = []

    init(patience: TimeInterval) {
        self.patience = patience
    }

    /// Whether the window has now stayed blank long enough.
    mutating func observe(_ look: WindowLook, at elapsed: TimeInterval) -> Bool {
        guard look.blank else {
            drawn.insert(look.window)
            return false
        }
        if drawn.contains(look.window) { return false }
        if window != look.window {
            window = look.window
            since = elapsed
            looks = 0
        }
        looks += 1
        return looks >= AttemptJudge.blankSamplesNeeded && elapsed - (since ?? elapsed) >= patience
    }
}
