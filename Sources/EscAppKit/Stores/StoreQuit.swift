import Foundation

/// When a store's client counts as closed. Steam, like most store clients, only hides its window when the player
/// closes it and goes on running with nothing on screen: no tray icon on a Mac to quit it from, a chat window
/// popping up by itself when a message came, and its web helper using a CPU core meanwhile. So a client the
/// player closed is quit, and so is one EscApp started for a game, once the game is over.
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

    /// - Parameter used: the client was found running already, before EscApp could see it used.
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

extension Store {
    /// Windows folders of the client and its services. A program anywhere else in the bottle is a game, apart
    /// from Windows' own.
    var clientFolders: [String] {
        switch self {
        case .steam: [#"C:\Program Files (x86)\Steam"#, #"C:\Program Files (x86)\Common Files\Steam"#]
        case .epic: [#"C:\Program Files\Epic Games\Launcher"#, #"C:\Program Files (x86)\Epic Games\Launcher"#,
                     #"C:\Program Files (x86)\Epic Games\Epic Online Services"#]
        case .gog: [#"C:\Program Files (x86)\GOG Galaxy"#]
        case .eaApp: [#"C:\Program Files\Electronic Arts\EA Desktop"#, #"C:\Program Files\Common Files\EAInstaller"#]
        case .ubisoft: [#"C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher"#]
        }
    }

    /// Where the client puts its games inside its own folder.
    var gameFolders: [String] {
        switch self {
        case .steam: [#"C:\Program Files (x86)\Steam\steamapps"#]
        case .gog: [#"C:\Program Files (x86)\GOG Galaxy\Games"#]
        case .ubisoft: [#"C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\games"#]
        case .epic, .eaApp: []
        }
    }

    /// Whether `program` (a Windows path) is the client's, or Windows' own, rather than a game.
    /// Wine's own Mac programs in the bottle (`wineserver`) have a Mac path and aren't games either.
    func isClientProgram(_ program: String) -> Bool {
        guard program.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil else { return true }
        if WineProcesses.runs(program, from: #"C:\windows"#) { return true }
        if program.lowercased().hasSuffix(#"\store-windows.exe"#) { return true }
        if gameFolders.contains(where: { WineProcesses.runs(program, from: $0) }) { return false }
        return clientFolders.contains { WineProcesses.runs(program, from: $0) }
    }
}

/// Steam's web helper is a Chromium: one browser process and a renderer for each page. Steam restarts the helper
/// now and then (ten times in an evening, more while its window was hidden), and in Wine the old browser's
/// renderers don't end with it: fifteen were left after 48 minutes, each using a fifth of a CPU core and the
/// bottle's wineserver nearly a whole one. A renderer is never older than its browser, so any helper process
/// started before the newest browser is one of those.
enum SteamHelperSweep {
    struct Helper: Equatable {
        var pid: pid_t
        var started: Date
        /// The browser itself; its renderers and services have a `--type=`.
        var isBrowser: Bool
    }

    static func helpers(in processes: [WineProcesses.Process]) -> [Helper] {
        processes.compactMap { process in
            guard process.program.lowercased().contains("steamwebhelper"), let started = process.started
            else { return nil }
            return Helper(pid: process.pid, started: started,
                          isBrowser: !process.arguments.contains { $0.hasPrefix("--type=") })
        }
    }

    /// The helper processes left over from earlier browsers. Without a browser, none: Steam is between helpers.
    static func strays(_ helpers: [Helper]) -> [pid_t] {
        guard let newest = helpers.filter(\.isBrowser).map(\.started).max() else { return [] }
        return helpers.filter { !$0.isBrowser && $0.started < newest }.map(\.pid)
    }
}

/// Steam getting a game ready: `GameAction [AppID 242920, ActionID 2] : LaunchApp changed task to …` lines in
/// `logs/console_log.txt`, from syncing the cloud and running install scripts to `Completed` or `Failed`. Its
/// window may be closed meanwhile with no game process yet, and quitting Steam then would cancel the launch.
enum SteamLaunches {
    static func file(in bottle: URL) -> URL {
        bottle.appending(path: "drive_c/Program Files (x86)/Steam/logs/console_log.txt")
    }

    /// A launch left unfinished this long ago is over: Steam was restarted, or the player never answered.
    static let staleAfter: TimeInterval = 5 * 60

    /// Whether the log's last word on some launch is neither `Completed` nor `Failed`, said in the last minutes.
    /// The log's times are the Mac's local time, like `[2026-10-24 22:35:31]`.
    static func inProgress(log: String, now: Date, timeZone: TimeZone = .current) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var last: [Substring: (time: Date, finished: Bool)] = [:]
        for line in log.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("["), line.count > 21,
                  let action = line.range(of: "GameAction ["), line.contains("] : LaunchApp "),
                  let time = formatter.date(from: String(line.dropFirst().prefix(19))),
                  let close = line[action.upperBound...].firstIndex(of: "]") else { continue }
            let finished = line.hasSuffix("task to Completed with \"\"") || line.hasSuffix("task to Failed with \"\"")
            last[line[action.upperBound..<close]] = (time, finished)
        }
        return last.values.contains { !$0.finished && now.timeIntervalSince($0.time) < staleAfter }
    }

    /// The same for the bottle's Steam, from the end of its log.
    static func inProgress(in bottle: URL, now: Date = Date()) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file(in: bottle)) else { return false }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 65_536 ? end - 65_536 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        // The read may start mid-character; a broken first line is skipped like any other.
        let text = String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
        return inProgress(log: text, now: now)
    }
}

/// Steam downloading or updating a game: `logs/content_log.txt` says each game's state as it changes,
/// `AppID 242920 state changed : Fully Installed,Update Queued,Update Running,`. On Windows a download goes on
/// with the window closed; quitting Steam then would stop it.
enum SteamDownloads {
    static func file(in bottle: URL) -> URL {
        bottle.appending(path: "drive_c/Program Files (x86)/Steam/logs/content_log.txt")
    }

    /// Whether the last state of some game, since Steam last started (`Client version: …`), has `Update Running`.
    /// A download Steam was quit in the middle of stays so in the log, and doesn't count after a restart.
    static func inProgress(log: String) -> Bool {
        var running: [Substring: Bool] = [:]
        for line in log.split(whereSeparator: \.isNewline) {
            if line.contains("] Client version: ") {
                running = [:]
            } else if let app = line.range(of: "] AppID "), let state = line.range(of: " state changed : ") {
                running[line[app.upperBound..<state.lowerBound]] = line[state.upperBound...]
                    .contains("Update Running,")
            }
        }
        return running.values.contains(true)
    }

    static func inProgress(in bottle: URL) -> Bool {
        guard let data = try? Data(contentsOf: file(in: bottle)) else { return false }
        // A long session's log grows by some kilobytes an hour; its end is what matters.
        let tail = data.suffix(4 << 20)
        return inProgress(log: String(bytes: tail, encoding: .utf8) ?? String(bytes: tail, encoding: .isoLatin1) ?? "")
    }
}
