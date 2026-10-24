import Darwin
import Foundation

/// Follows a game started through its store's client. The `wine` EscApp starts only hands `-applaunch` to the
/// client (or becomes the client, when it wasn't running) and the game appears later as a process of its own,
/// after the store's sign-in or an update if those come first. The bottle never goes quiet while the client
/// runs, so the game's end is when no process from its folder is left.
///
/// Steam also says itself when it starts and loses a game (`SteamGameLog`). That covers a game that starts
/// itself again: Banished's first process ends with -1 and Steam starts a new one 27 s later, which the
/// 3-second rule took for the end. And a game whose processes EscApp can't tell apart still ends when Steam
/// says so: its first launch waited for minutes after the game had closed.
struct StoreGameWatch: Sendable {
    let bottle: URL
    /// The game's folder as Windows sees it.
    let folder: String
    /// The Steam app id, for a Steam game.
    var steamApp: String?

    /// How long the game may take to appear: the client may first update itself, or wait for the player to sign in.
    static let appearTimeout: TimeInterval = 30 * 60
    /// Seconds without any of its processes that make the game over. A game restarting itself (a launcher that
    /// starts the game, a settings window first) leaves a gap of a moment.
    static let goneFor = 3
    /// The same after Steam saw the game end with an error, which is how a game restarting itself through Steam
    /// ends its first process.
    static let goneAfterErrorFor = 45

    /// Feeds `game` once the game has come and gone. `starter` is the `wine` EscApp started: if it fails before
    /// the game appears (no client), so did the game.
    /// - Parameter restart: closes the store's client and starts the game through it again, returning the new
    ///   starter; used once, for a Steam stuck at start (`SteamStartCheck`).
    func watch(starter: ProcessExit, game: ProcessExit,
               restart: (@Sendable () async -> ProcessExit?)? = nil) {
        let steamLog = steamApp.map { SteamGameLog.Reader(file: SteamGameLog.file(in: bottle), appID: $0) }
        Task.detached {
            var started = Date()
            var starter = starter
            var restarted = false
            var seen = false
            var missing = 0
            var steam = SteamGameLog.State()
            while true {
                steamLog?.read(into: &steam)
                let running = !WineProcesses.game(in: bottle, folder: folder).isEmpty
                if running || steam.running {
                    seen = true
                    missing = 0
                } else if !seen, steamApp != nil, !restarted, let restart,
                          SteamStartCheck.stuck(in: bottle, startedAt: started) {
                    restarted = true
                    if let again = await restart() {
                        starter = again
                        started = Date()
                    }
                } else if !seen, steamApp != nil, restarted, SteamStartCheck.stuck(in: bottle, startedAt: started) {
                    // Stuck again after a restart: the launch ends rather than wait for half an hour.
                    return game.exited(1)
                } else if seen {
                    missing += 1
                    let limit = (steam.lastExit ?? 0) != 0 ? Self.goneAfterErrorFor : Self.goneFor
                    if missing >= limit { return game.exited(steam.lastExit ?? 0) }
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

/// Steam's `logs/gameprocess_log.txt`: `AppID 242920 adding PID 384 as a tracked process …` when it starts a
/// game, `AppID 242920 no longer tracking PID 384, exit code -1` and `Remove 242920 from running list` when it
/// ends.
enum SteamGameLog {
    struct State: Equatable {
        var running = false
        /// The exit code of the game's last process to end.
        var lastExit: Int32?
    }

    static func file(in bottle: URL) -> URL {
        bottle.appending(path: "drive_c/Program Files (x86)/Steam/logs/gameprocess_log.txt")
    }

    /// Applies the lines about `appID`, in order, to `state`.
    static func apply(_ text: String, appID: String, to state: inout State) {
        for line in text.split(whereSeparator: \.isNewline) {
            if line.contains("AppID \(appID) adding PID ") {
                state.running = true
            } else if line.contains("AppID \(appID) no longer tracking PID "),
                      let code = line.split(separator: " ").last.flatMap({ Int32($0) }) {
                state.lastExit = code
            } else if line.contains("Remove \(appID) from running list") {
                state.running = false
            }
        }
    }

    /// Reads what Steam wrote since the launch: only lines from now on are about this launch.
    final class Reader: @unchecked Sendable {
        let file: URL
        let appID: String
        private var offset: UInt64
        private var partial = ""

        init(file: URL, appID: String) {
            self.file = file
            self.appID = appID
            offset = Self.size(of: file)
        }

        func read(into state: inout State) {
            let size = Self.size(of: file)
            // Steam starts a new file when it starts: read that one from the top.
            if size < offset { offset = 0; partial = "" }
            guard size > offset, let handle = try? FileHandle(forReadingFrom: file) else { return }
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            let data = (try? handle.readToEnd()) ?? Data()
            offset += UInt64(data.count)
            let text = partial + (String(bytes: data, encoding: .utf8) ?? "")
            // A line Steam is still writing waits for the next read.
            let complete = text.lastIndex(where: \.isNewline).map { text[...$0] } ?? ""
            partial = String(text[complete.endIndex...])
            SteamGameLog.apply(String(complete), appID: appID, to: &state)
        }

        static func size(of file: URL) -> UInt64 {
            ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        }
    }
}

/// Steam stuck at start, which waiting can't fix: its `steam.exe` runs, its web helper never started, and it
/// hasn't written to any of its logs for a while. On Wine 11.20 build 4 a Steam started right after EscApp had
/// shut it down stopped like that after "Verification skipped" and waited for good, and the game's launch
/// window with it. A Steam that is updating, signing in or asking something writes its logs or shows its helper.
enum SteamStartCheck {
    static let quietFor: TimeInterval = 45

    static func stuck(clientRunning: Bool, helperRunning: Bool, lastLogWrite: Date?, startedAt: Date,
                      now: Date) -> Bool {
        guard clientRunning, !helperRunning, now.timeIntervalSince(startedAt) >= quietFor else { return false }
        return now.timeIntervalSince(max(lastLogWrite ?? startedAt, startedAt)) >= quietFor
    }

    static func stuck(in bottle: URL, startedAt: Date, now: Date = Date()) -> Bool {
        let programs = WineProcesses.running(in: bottle).map { $0.program.lowercased() }
        return stuck(clientRunning: programs.contains { $0.hasSuffix("\\steam.exe") || $0.hasSuffix("/steam.exe") },
                     helperRunning: programs.contains { $0.contains("steamwebhelper") },
                     lastLogWrite: lastLogWrite(in: bottle), startedAt: startedAt, now: now)
    }

    /// When Steam last wrote any of its logs.
    static func lastLogWrite(in bottle: URL) -> Date? {
        let logs = bottle.appending(path: "drive_c/Program Files (x86)/Steam/logs", directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys:
            [.contentModificationDateKey])) ?? []
        return files.compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max()
    }
}
