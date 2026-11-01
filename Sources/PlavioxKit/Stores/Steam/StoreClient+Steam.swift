import Foundation

/// Steam's first update, done by Plaviox so its window never opens black.
extension StoreClient {
    /// Steam's installer only puts down a bootstrapper. Its first start downloads the client in two rounds,
    /// each ending with Steam restarting itself: an older 32-bit client first, then the current 64-bit one.
    /// Once the second round is in, Steam is stopped before its window opens: that start would run its web
    /// helper unwrapped and show a black window. The next "Open Steam" starts it wrapped.
    func updateSteam(_ client: URL, wine: Wine, environment: [String: String], in bottle: URL,
                     progress: @escaping @Sendable (Step) -> Void) async throws {
        let log = Self.steamBootstrapLog(bottle)
        let starter = Task {
            try await Self.run(wine, [client.path(percentEncoded: false), "-silent"]
                                   + Store.steam.clientArguments(clientReady: false),
                               in: client.deletingLastPathComponent(), environment: environment,
                               log: newLog(.steam, "update"))
        }
        let deadline = Date().addingTimeInterval(20 * 60)
        var last: (Int64, Int64)?
        while !Self.steamReady(bottle), Date() < deadline {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if let counted = Self.steamDownload(in: text), counted != last.map({ ($0.0, $0.1) }) ?? (-1, -1) {
                last = counted
                progress(.updating(received: counted.0, total: counted.1))
            }
            try await Task.sleep(for: .seconds(1))
        }
        _ = try? await ProcessRunner.run(wine.wineserver.path, ["-k"], environment: environment)
        _ = try? await ProcessRunner.run(wine.wineserver.path, ["-w"], environment: environment)
        let status = (try? await starter.value) ?? -1
        guard Self.steamReady(bottle) else { throw StoreError.updateFailed(status) }
        try ChromiumHelper.wrap(.steam, in: bottle)
    }

    static func steamBootstrapLog(_ bottle: URL) -> URL {
        bottle.appending(path: "drive_c/Program Files (x86)/Steam/logs/bootstrap_log.txt")
    }

    /// Steam's current client is in: the 64-bit round of its first update finished (its log says
    /// `Shutdown` after taking the `steam_client_win64` manifest) and its web helper is there.
    static func steamReady(_ bottle: URL) -> Bool {
        let steam = bottle.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: steam.appending(path: "package/steam_client_win64.installed").path),
              !ChromiumHelper.expand(Store.steam.chromiumHelpers[0], in: bottle.appending(path: "drive_c")).isEmpty
        else { return false }
        let text = (try? String(contentsOf: steamBootstrapLog(bottle), encoding: .utf8)) ?? ""
        return steamUpdateFinished(log: text)
    }

    /// Whether the log shows the 64-bit round complete. Later starts check the same manifest and write
    /// `Download skipped`; only `Downloaded new manifest` starts a round. A client that updated itself long ago
    /// has no round in its log any more; then the installed manifest alone counts.
    static func steamUpdateFinished(log text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        guard let round = lines.lastIndex(where: { $0.contains("Downloaded new manifest: /steam_client_win64") })
        else { return true }
        return lines[(round + 1)...].contains { $0.contains("] Shutdown") }
    }

    /// `Downloading update (13,352 of 239,614 KB)...`, in whatever language Steam speaks: the last two numbers in
    /// parentheses.
    static func steamDownload(in log: String) -> (Int64, Int64)? {
        guard let line = log.components(separatedBy: .newlines).last(where: {
            $0.range(of: #"\([\d,. ]+ \S+ [\d,. ]+ \S+\)"#, options: .regularExpression) != nil
        }), let range = line.range(of: #"\([\d,. ]+ \S+ [\d,. ]+ \S+\)"#, options: .regularExpression) else {
            return nil
        }
        let numbers = line[range].split(separator: " ").compactMap { Int64($0.filter(\.isNumber)) }
        guard numbers.count == 2, numbers[1] > 0 else { return nil }
        return (numbers[0], numbers[1])
    }
}
