import Foundation

/// When a store's client counts as closed. Steam, like most store clients, only hides its window when the player
/// closes it and goes on running with nothing on screen: no tray icon on a Mac to quit it from, a chat window
/// popping up by itself when a message came, and its web helper using a CPU core meanwhile. So a client the
/// player closed is quit, and so is one Magic Kettle started for a game, once the game is over.
///
/// The client must first have been seen in use (a window, or a game running), so one starting up, updating itself
/// or signing in quietly before a game appears is left alone.
public struct StoreQuit: Sendable, Equatable {
    /// Seconds without a window after the player closed the client's last one: Steam's sign-in and main windows
    /// leave a moment between them.
    static let afterWindow: TimeInterval = 8
    /// Seconds after its game ended: Banished starts itself again through Steam, 27 s after its first process.
    static let afterGame: TimeInterval = 60

    private var used = false
    private var lastWasGame = false
    private var quietSince: Date?

    /// - Parameter used: the client was found running already, before Magic Kettle could see it used.
    public init(used: Bool = false) { self.used = used }

    /// Feeds one look at the client's bottle; true once the client should be quit.
    /// - Parameters:
    ///   - windows: any window shown in the bottle, minimised ones included.
    ///   - game: any process in the bottle that isn't the client's or Windows' own.
    public mutating func update(windows: Bool, game: Bool, now: Date) -> Bool {
        if windows || game {
            used = true
            lastWasGame = game
            quietSince = nil
            return false
        }
        guard used else { return false }
        let since = quietSince ?? now
        quietSince = since
        return now.timeIntervalSince(since) >= (lastWasGame ? Self.afterGame : Self.afterWindow)
    }

    /// Whether a look at the bottle's windows from inside Wine is worth it: only for a client already used.
    public var watching: Bool { used }
}

/// Windows as Windows sees them in a store's bottle (`tools/store-windows`). From the Mac a hidden window and a
/// minimised one are both just off screen; only Wine can tell a closed client from a minimised one.
public enum StoreWindows {
    struct Window: Equatable {
        var pid: Int
        var minimised: Bool
        var title: String
    }

    static var program: URL? { Bundle.module.url(forResource: "store-windows", withExtension: "exe") }

    /// The helper's lines, "<pid>\t<0|1>\t<title>"; anything else (Wine's own messages) is skipped.
    static func parse(_ output: String) -> [Window] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, let pid = Int(parts[0]), parts[1] == "0" || parts[1] == "1" else { return nil }
            return Window(pid: pid, minimised: parts[1] == "1", title: parts.count > 2 ? String(parts[2]) : "")
        }
    }

    /// Whether anything in `bottle` has a window shown; nil when the helper couldn't run, which counts as yes.
    static func anyShown(in bottle: URL, wine: Wine, host: [String: String]) async -> Bool? {
        guard let program else { return nil }
        let environment = WineEnvironment.make(host: host, bottle: bottle.path,
                                               fastSync: WineEnvironment.fastSync(for: nil, wine: wine))
        // A limit: the helper itself can't wait on a window (`InternalGetWindowText`), but Wine under it can.
        guard let result = try? await ProcessRunner.run(wine.wine.path, [program.path(percentEncoded: false)],
                                                        environment: environment, timeout: 8),
              result.status == 0 else { return nil }
        return !parse(result.output).isEmpty
    }
}
