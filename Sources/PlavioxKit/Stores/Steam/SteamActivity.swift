import Darwin
import Foundation

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

    /// How long a browser must have run before it counts. Wine starts a process by forking its parent and then
    /// running the new program, and in between the new process still shows its parent's arguments: a browser
    /// starting a renderer briefly looks like a newer browser. Counted as one, it had every live renderer and the
    /// network service killed, and Steam restarted its window five times in three minutes.
    static let browserSettledAfter: TimeInterval = 10

    /// The helper processes left over from earlier browsers. Without a browser, none: Steam is between helpers.
    static func strays(_ helpers: [Helper], now: Date = Date()) -> [pid_t] {
        guard let newest = helpers.filter({ $0.isBrowser && now.timeIntervalSince($0.started) >= browserSettledAfter })
            .map(\.started).max() else { return [] }
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
        inProgress(log: tail(in: bottle), now: now)
    }

    /// How long Steam has to wait on a step before it counts as asking the player: the steps it answers itself
    /// (`ShowInterstitials` with nothing to show, `CreatingProcess`) go on within two seconds.
    static let askingAfter: TimeInterval = 5

    /// The step a launch of `appID` waits on the player for, like `KickingOtherSession` (a session playing
    /// Spacewar elsewhere had to be ended first): `LaunchApp waiting for user response to KickingOtherSession …`
    /// with no later line for that launch, said at least `askingAfter` ago. Steam asks in its own window, which
    /// isn't shown while it runs without one, and Among Us waited 14 minutes behind Plaviox's "Starting".
    static func question(log: String, appID: String, now: Date, timeZone: TimeZone = .current) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let waiting = "LaunchApp waiting for user response to "
        var asked: (step: Substring, time: Date)?
        for line in log.split(whereSeparator: \.isNewline) {
            if line.contains("] Client version: ") { asked = nil; continue }
            guard line.contains("GameAction [AppID \(appID),"), line.contains("] : LaunchApp ") else { continue }
            guard let range = line.range(of: waiting),
                  let time = formatter.date(from: String(line.dropFirst().prefix(19))) else {
                asked = nil
                continue
            }
            asked = (line[range.upperBound...].prefix { $0 != " " }, time)
        }
        guard let asked, now.timeIntervalSince(asked.time) >= askingAfter else { return nil }
        return String(asked.step)
    }

    static func question(in bottle: URL, appID: String, now: Date = Date()) -> String? {
        question(log: tail(in: bottle), appID: appID, now: now)
    }

    /// The end of the bottle's Steam log.
    private static func tail(in bottle: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file(in: bottle)) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 65_536 ? end - 65_536 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        // The read may start mid-character; a broken first line is skipped like any other.
        return String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
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
