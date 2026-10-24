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
        var wine: WarmWine?
        var hold: (any WineHold)?
    }

    private let steps: any WarmUpSteps
    private let memory: UInt64
    private var entries: [GameID: Entry] = [:]
    /// Warm-ups whose game was launched before they finished: they stop, but leave Wine running for the game.
    private var released: Set<UUID> = []
    /// Oldest first.
    private var order: [GameID] = []

    /// - Parameters:
    ///   - steps: what warming does to Wine; tests pass a script.
    ///   - memory: the Mac's memory, compared with `minimumMemory`.
    public init(paths: AppPaths, host: [String: String] = ProcessInfo.processInfo.environment,
                steps: (any WarmUpSteps)? = nil, memory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.steps = steps ?? WineWarmUp(paths: paths, host: host)
        self.memory = memory
    }

    public var warmGames: [GameID] { order }

    /// Warms the game's bottle if it already exists for this runtime. A game that never ran has no bottle,
    /// and making one (and maybe the template, ~35 s) is left to its first launch.
    public func warm(_ game: GameRecord, runtime: RuntimeManifest.Runtime) async {
        guard memory >= Self.minimumMemory else { return }
        if entries[game.id] != nil {
            order.removeAll { $0 == game.id }
            order.append(game.id)
            return
        }
        guard steps.canWarm(game, runtime: runtime) else { return }
        while order.count >= Self.limit, let oldest = order.first { await cool(oldest) }

        let entry = Entry()
        entries[game.id] = entry
        order.append(game.id)
        func stillWanted() -> Bool { entries[game.id]?.token == entry.token }

        let wine = await steps.boot(game, runtime: runtime)
        guard stillWanted() else {
            // Cooled while starting: what started has to go, unless the game itself is starting in it.
            if released.remove(entry.token) == nil, let wine { await steps.shutDown(wine) }
            return
        }
        guard let wine, let hold = steps.hold(wine) else {
            forget(game.id)
            if let wine { await steps.shutDown(wine) }
            return
        }
        entries[game.id]?.wine = wine
        entries[game.id]?.hold = hold
    }

    /// The game is starting in its warm bottle: the helper goes, the running Windows stays for the game. Without
    /// this the bottle would never go idle after the game, and EscApp would think the game was still running.
    public func release(_ id: GameID) {
        guard let entry = entries[id] else { return }
        if entry.hold == nil { released.insert(entry.token) }
        forget(id)
        entry.hold?.release()
    }

    /// Shuts the game's warm bottle down at once.
    public func cool(_ id: GameID) async {
        guard let entry = entries[id] else { return }
        forget(id)
        entry.hold?.release()
        if let wine = entry.wine { await steps.shutDown(wine) }
    }

    public func coolAll(except kept: GameID? = nil) async {
        for id in order where id != kept { await cool(id) }
    }

    private func forget(_ id: GameID) {
        entries[id] = nil
        order.removeAll { $0 == id }
    }
}

/// A bottle whose Wine is running.
public struct WarmWine: Sendable {
    public var wine: Wine
    public var environment: [String: String]
}

/// Keeps a warm bottle's Wine up until released.
public protocol WineHold: Sendable {
    func release()
}

/// What warming does to Wine, apart from the bookkeeping in `BottleWarmer`.
public protocol WarmUpSteps: Sendable {
    /// Whether the game has a bottle for this runtime to warm.
    func canWarm(_ game: GameRecord, runtime: RuntimeManifest.Runtime) -> Bool
    /// Applies the game's settings and starts the bottle's Wine. Nil when it can't.
    func boot(_ game: GameRecord, runtime: RuntimeManifest.Runtime) async -> WarmWine?
    /// Keeps the Wine up; nil when it can't.
    func hold(_ wine: WarmWine) -> (any WineHold)?
    /// Stops everything in the bottle at once.
    func shutDown(_ wine: WarmWine) async
}

/// The real steps: `GameLauncher.prepare` for the settings, then Wine's server, services and desktop.
struct WineWarmUp: WarmUpSteps {
    let paths: AppPaths
    let host: [String: String]

    func canWarm(_ game: GameRecord, runtime: RuntimeManifest.Runtime) -> Bool {
        let bottles = BottleManager(paths: paths, host: host)
        return Self.canWarm(game, bottleRuntime: bottles.bottleInfo(for: game.id)?.runtime, current: runtime.id,
                            hasTemplate: bottles.hasTemplate(for: runtime))
    }

    /// Warming a disc game would attach its image just for hovering over it, and a store game's bottle is its
    /// store's, started with the client. A game that never ran has no bottle. One made by an earlier runtime is
    /// moved onto the current one first, as a launch does, when that runtime's template is ready (a clone, a
    /// second or two): after each runtime update the last played game started cold until it was played once.
    static func canWarm(_ game: GameRecord, bottleRuntime: String?, current: String, hasTemplate: Bool) -> Bool {
        guard game.disc == nil, game.store == nil, let bottleRuntime else { return false }
        return bottleRuntime == current || hasTemplate
    }

    func boot(_ game: GameRecord, runtime: RuntimeManifest.Runtime) async -> WarmWine? {
        guard let prepared = try? await GameLauncher(paths: paths, host: host).prepare(game, runtime: runtime) else {
            return nil
        }
        // Starts the server and Windows' services, and the desktop process the first window waits for.
        // Not `ProcessRunner`: it waits for its output pipe to close, and the server and services this starts
        // inherit it, so it would only return once the bottle had shut down again.
        await Self.runQuietly(prepared.wine, ["rundll32.exe", "user32.dll,GetDesktopWindow"],
                              environment: prepared.environment)
        return WarmWine(wine: prepared.wine, environment: prepared.environment)
    }

    func hold(_ wine: WarmWine) -> (any WineHold)? {
        let helper = Process()
        let input = Pipe()
        helper.executableURL = wine.wine.wine
        helper.arguments = ["cmd.exe", "/c", "pause"]
        helper.environment = wine.environment
        helper.standardInput = input
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        guard (try? helper.run()) != nil else { return nil }
        return HelperHold(helper: helper, input: input)
    }

    func shutDown(_ wine: WarmWine) async {
        _ = try? await ProcessRunner.run(wine.wine.wineserver.path, ["-k"], environment: wine.environment)
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
}

/// The idle `cmd /c pause`: it waits on a pipe EscApp holds, so it also ends when EscApp does.
private final class HelperHold: WineHold, @unchecked Sendable {
    private let helper: Process
    private let input: Pipe

    init(helper: Process, input: Pipe) {
        self.helper = helper
        self.input = input
    }

    func release() {
        try? input.fileHandleForWriting.close()
        if helper.isRunning { helper.terminate() }
    }
}
