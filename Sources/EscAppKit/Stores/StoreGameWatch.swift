import Darwin
import Foundation

/// Follows a game started through its store's client. The `wine` EscApp starts only hands `-applaunch` to the
/// client (or becomes the client, when it wasn't running) and the game appears later as a process of its own,
/// after the store's sign-in or an update if those come first. The bottle never goes quiet while the client
/// runs, so the game's end is when no process from its folder is left.
struct StoreGameWatch: Sendable {
    let bottle: URL
    /// The game's folder as Windows sees it.
    let folder: String

    /// How long the game may take to appear: the client may first update itself, or wait for the player to sign in.
    static let appearTimeout: TimeInterval = 30 * 60
    /// Seconds without any of its processes that make the game over. A game restarting itself (a launcher that
    /// starts the game, a settings window first) leaves a gap of a moment.
    static let goneFor = 3

    /// Feeds `game` once the game has come and gone. `starter` is the `wine` EscApp started: if it fails before
    /// the game appears (no client), so did the game.
    func watch(starter: ProcessExit, game: ProcessExit) {
        Task.detached {
            let started = Date()
            var seen = false
            var missing = 0
            while true {
                if !WineProcesses.game(in: bottle, folder: folder).isEmpty {
                    seen = true
                    missing = 0
                } else if seen {
                    missing += 1
                    if missing >= Self.goneFor { return game.exited(0) }
                } else if let code = starter.code, code != 0, Date().timeIntervalSince(started) > 10 {
                    return game.exited(code)
                } else if Date().timeIntervalSince(started) > Self.appearTimeout {
                    return game.exited(1)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Ends the game's processes, asking first; the client keeps running.
    func stop() async {
        for pid in WineProcesses.game(in: bottle, folder: folder) { kill(pid, SIGTERM) }
        try? await Task.sleep(for: .seconds(3))
        for pid in WineProcesses.game(in: bottle, folder: folder) { kill(pid, SIGKILL) }
    }
}
