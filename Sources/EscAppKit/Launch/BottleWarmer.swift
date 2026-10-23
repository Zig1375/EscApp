import Foundation

/// Starts a game's Wine before Play is pressed, so the game's window appears in about half a second instead of
/// two to three.
///
/// Most of a cold start is Wine itself: the bottle's wineserver, Windows' services, and the desktop process
/// that the first window needs (measured on an M2 Max: 1.7 s of 2.2 s). A warm bottle keeps those running,
/// held up by a helper that does nothing (`cmd /c pause`). It costs about 117 MB and under 1% of one core
/// while it waits.
///
/// The helper reads from a pipe EscApp holds: if EscApp quits or crashes, the pipe closes, the helper exits,
/// and Wine shuts the bottle down by itself a few seconds later. Nothing outlives EscApp.
///
/// Registry changes need the bottle's server stopped (see `WineRegistry`), so a warm-up applies the game's
/// settings first, exactly like a launch, and the app cools a bottle before its settings change.
public actor BottleWarmer {
    /// At most this many bottles are kept warm; warming another cools the one warmed longest ago.
    public static let limit = 2
    /// Macs with less memory than this don't warm at all: ~117 MB per bottle matters there.
    public static let minimumMemory: UInt64 = 16 << 30

    private struct Entry {
        /// Tells a warm-up that was cooled while it ran from a newer one for the same game.
        let token = UUID()
        var helper: Process?
        var input: Pipe?
        var wine: Wine?
        var environment: [String: String] = [:]
    }

    private let paths: AppPaths
    private let host: [String: String]
    private var entries: [GameID: Entry] = [:]
    /// Warm-ups whose game was launched before they finished: they stop, but leave Wine running for the game.
    private var released: Set<UUID> = []
    /// Oldest first.
    private var order: [GameID] = []

    public init(paths: AppPaths, host: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.host = host
    }

    /// Whether this Mac warms bottles at all.
    public static var isAllowed: Bool { ProcessInfo.processInfo.physicalMemory >= minimumMemory }

    public var warmGames: [GameID] { order }

    /// Warms the game's bottle if it already exists for this runtime. A game that never ran has no bottle,
    /// and making one (and maybe the template, ~35 s) is left to its first launch.
    public func warm(_ game: GameRecord, runtime: RuntimeManifest.Runtime) async {
        guard Self.isAllowed else { return }
        if entries[game.id] != nil {
            order.removeAll { $0 == game.id }
            order.append(game.id)
            return
        }
        guard BottleManager(paths: paths, host: host).bottleInfo(for: game.id)?.runtime == runtime.id else { return }
        while order.count >= Self.limit, let oldest = order.first { await cool(oldest) }

        let entry = Entry()
        entries[game.id] = entry
        order.append(game.id)
        func stillWanted() -> Bool { entries[game.id]?.token == entry.token }

        guard let prepared = try? await GameLauncher(paths: paths, host: host).prepare(game, runtime: runtime),
              stillWanted() else {
            if stillWanted() { forget(game.id) }
            released.remove(entry.token)
            return
        }
        entries[game.id]?.wine = prepared.wine
        entries[game.id]?.environment = prepared.environment
        // Starts the server and Windows' services, and the desktop process the first window waits for.
        // Not `ProcessRunner`: it waits for its output pipe to close, and the server and services this starts
        // inherit it, so it would only return once the bottle had shut down again.
        await Self.runQuietly(prepared.wine, ["rundll32.exe", "user32.dll,GetDesktopWindow"],
                              environment: prepared.environment)
        guard stillWanted() else {
            // Cooled while starting: what started has to go, unless the game itself is starting in it.
            if released.remove(entry.token) == nil {
                await kill(wine: prepared.wine, environment: prepared.environment)
            }
            return
        }
        let helper = Process()
        let input = Pipe()
        helper.executableURL = prepared.wine.wine
        helper.arguments = ["cmd.exe", "/c", "pause"]
        helper.environment = prepared.environment
        helper.standardInput = input
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        guard (try? helper.run()) != nil else {
            forget(game.id)
            await kill(wine: prepared.wine, environment: prepared.environment)
            return
        }
        entries[game.id]?.helper = helper
        entries[game.id]?.input = input
    }

    /// The game is starting in its warm bottle: the helper goes, the running Windows stays for the game. Without
    /// this the bottle would never go idle after the game, and EscApp would think the game was still running.
    public func release(_ id: GameID) {
        guard let entry = entries[id] else { return }
        if entry.helper == nil { released.insert(entry.token) }
        forget(id)
        stopHelper(entry)
    }

    /// Shuts the game's warm bottle down at once.
    public func cool(_ id: GameID) async {
        guard let entry = entries[id] else { return }
        forget(id)
        stopHelper(entry)
        if let wine = entry.wine { await kill(wine: wine, environment: entry.environment) }
    }

    public func coolAll(except kept: GameID? = nil) async {
        for id in order where id != kept { await cool(id) }
    }

    private func forget(_ id: GameID) {
        entries[id] = nil
        order.removeAll { $0 == id }
    }

    private func stopHelper(_ entry: Entry) {
        try? entry.input?.fileHandleForWriting.close()
        if entry.helper?.isRunning == true { entry.helper?.terminate() }
    }

    /// Runs a Wine program with its output discarded and waits for that process alone.
    private static func runQuietly(_ wine: Wine, _ arguments: [String], environment: [String: String]) async {
        let process = Process()
        process.executableURL = wine.wine
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume()
            }
        }
    }

    private func kill(wine: Wine, environment: [String: String]) async {
        _ = try? await ProcessRunner.run(wine.wineserver.path, ["-k"], environment: environment)
    }
}
