import Darwin
import Foundation

/// The Epic Games Launcher updates itself by downloading the new version, quitting, and leaving a small
/// "Installing updates" window (`EpicGamesUpdater.exe start`) while its Windows service installs it. In Wine
/// that service's install step fails at once (`selfupdateinstall` exits with 777006 when run as the service), and
/// the window waits forever. The same step run as the player works, so EscApp runs it itself: right after the
/// download, and before any start that finds a downloaded update not yet installed.
extension StoreClient {
    /// The first start after installing: the launcher downloads its current version (~670 MB), which is then
    /// installed. Without an update to fetch it is left alone after a few minutes.
    func updateEpic(_ client: URL, wine: Wine, environment: [String: String]) async throws {
        let bottle = bottle(for: .epic)
        try start(wine, client, Store.epic.clientArguments(clientReady: true), store: .epic)
        let started = Date()
        while Date().timeIntervalSince(started) < 20 * 60 {
            if Self.epicUpdaterWaits(in: bottle) { break }
            if Date().timeIntervalSince(started) > 3 * 60, !Self.epicHasStagedUpdate(bottle) { break }
            try await Task.sleep(for: .seconds(2))
        }
        await shutDown(.epic)
        if Self.epicHasStagedUpdate(bottle) { await applyEpicUpdate(wine: wine) }
        await shutDown(.epic)
    }

    /// While the launcher runs from "Open": once it has quit for an update, the update is installed and the
    /// launcher started again. And a launcher stuck on its Epic logo is set going again. Its web page process
    /// sometimes spins at start and never loads the store pages (no `LogWebView` line ever reaches its log): six
    /// starts in fifteen on one Mac, more while the Mac was busy, and a launcher restarted for it got stuck the
    /// same way. Ending only that process works: the launcher starts a new one ("Render process terminated …
    /// recovery attempt 1/3") and its pages were there six seconds later. A full restart is the last resort.
    func watchEpicUpdates(_ client: URL, wine: Wine) {
        let client = client
        Task.detached { [self] in
            let bottle = bottle(for: .epic)
            var started = Date()
            var waiting = started
            var restarts = 0
            var rendererKills = 0
            let deadline = Date().addingTimeInterval(60 * 60)
            while Date() < deadline, isRunning(.epic) {
                if Self.epicUpdaterWaits(in: bottle) {
                    await shutDown(.epic)
                    await applyEpicUpdate(wine: wine)
                    try? start(wine, client, Store.epic.clientArguments(clientReady: true), store: .epic)
                    return
                }
                if Date().timeIntervalSince(waiting) > Self.epicPagesTimeout,
                   !Self.epicPagesLoaded(in: bottle, since: started) {
                    if rendererKills < Self.epicRendererKills,
                       let renderer = Self.busiestRenderer(WineProcesses.running(in: bottle),
                                                           cpu: WineProcesses.cpuTime) {
                        rendererKills += 1
                        kill(renderer, SIGKILL)
                    } else if restarts < Self.epicStuckRestarts {
                        restarts += 1
                        rendererKills = 0
                        await shutDown(.epic)
                        try? start(wine, client, Store.epic.clientArguments(clientReady: true), store: .epic)
                        started = Date()
                    }
                    waiting = Date()
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// How long the launcher gets to show its store pages: they came in 14 to 40 s when it didn't get stuck.
    static let epicPagesTimeout: TimeInterval = 45
    /// How many times its web page process is ended (the launcher recovers it three times), and how many times
    /// the launcher is then restarted.
    static let epicRendererKills = 2
    static let epicStuckRestarts = 1

    /// The launcher's web page process that has used the most CPU: the stuck one spins, the others wait.
    static func busiestRenderer(_ processes: [WineProcesses.Process], cpu: (pid_t) -> UInt64?) -> pid_t? {
        processes.filter { process in
            let name = process.program.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last ?? ""
            return name.lowercased() == "epicwebhelper.exe" && process.arguments.contains("--type=renderer")
        }
        .compactMap { process in cpu(process.pid).map { (process.pid, $0) } }
        .max { $0.1 < $1.1 }?.0
    }

    /// Whether the launcher started at `since` has shown its web pages: its log names them as they load.
    static func epicPagesLoaded(in bottle: URL, since: Date) -> Bool {
        let logs = bottle.appending(path: "drive_c/users", directoryHint: .isDirectory)
        let users = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? []
        return users.contains { user in
            let log = user.appending(path: "AppData/Local/EpicGamesLauncher/Saved/Logs/EpicGamesLauncher.log")
            guard let modified = (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate, modified >= since,
                let data = try? Data(contentsOf: log) else { return false }
            return showsPages(data)
        }
    }

    static func showsPages(_ log: Data) -> Bool {
        log.range(of: Data("LogWebView".utf8)) != nil
    }

    /// Runs the launcher's own install step for the downloaded update, as the player.
    func applyEpicUpdate(wine: Wine, in bottle: URL? = nil) async {
        let bottle = bottle ?? self.bottle(for: .epic)
        guard let client = Store.epic.client(in: bottle) else { return }
        let environment = WineEnvironment.make(host: host, bottle: bottle.path, extra: Store.epic.environment,
                                               fastSync: WineEnvironment.fastSync(for: nil, wine: wine))
        _ = try? await Self.run(wine, [client.path(percentEncoded: false)] + Self.epicSelfUpdateArguments,
                                in: client.deletingLastPathComponent(), environment: environment,
                                log: newLog(.epic, "update"))
    }

    static let epicSelfUpdateArguments = ["-Commandlet=selfupdateinstall", "-epicenv=Prod"]

    /// Where the launcher puts a downloaded update; installing it empties the folder again.
    static func epicUpdateStage(_ bottle: URL) -> URL {
        bottle.appending(path: "drive_c/ProgramData/Epic/EpicGamesLauncher/Data/Update/Install",
                         directoryHint: .isDirectory)
    }

    static func epicHasStagedUpdate(_ bottle: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(at: epicUpdateStage(bottle),
                                                          includingPropertiesForKeys: [.isRegularFileKey]) else {
            return false
        }
        for case let file as URL in walker
        where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            return true
        }
        return false
    }

    /// The "Installing updates" window is up: the updater started with `start`, not as the service.
    static func epicUpdaterWaits(in bottle: URL) -> Bool {
        WineProcesses.running(in: bottle).contains(where: isWaitingUpdater)
    }

    static func isWaitingUpdater(_ process: WineProcesses.Process) -> Bool {
        let name = process.program.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last ?? ""
        return name.lowercased() == "epicgamesupdater.exe" && process.arguments.first?.lowercased() == "start"
    }
}
