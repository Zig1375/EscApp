import Foundation

/// Starts a game the way the app and `exeport run` both do, and waits until it is fully closed.
///
/// One launch: read the exe, pick the backend, make sure the bottle exists and carries the game's Windows
/// version and Retina choice, start `wine <exe>` from the game's folder with output going to a log, then wait for
/// the bottle's wineserver to exit. Waiting on wineserver rather than on `wine` matters: a launcher often starts
/// the real game and quits, and the game is only done when nothing runs in the bottle any more.
public struct GameLauncher: Sendable {
    public struct Prepared: Sendable {
        public var game: GameRecord
        public var info: ExecutableInfo
        public var backend: GraphicsBackend
        public var bottle: URL
        public var wine: Wine
        public var environment: [String: String]
        public var log: URL
    }

    public struct Outcome: Sendable, Equatable {
        public var exitCode: Int32
        /// Until everything in the bottle stopped: the play time.
        public var duration: TimeInterval
        /// Until the started program itself exited. Wine keeps its server up for a few seconds afterwards, so
        /// this, not `duration`, tells a crash at start from a session.
        public var processDuration: TimeInterval
        public var backend: GraphicsBackend
        public var log: URL
    }

    /// How many logs to keep per game.
    static let keptLogs = 20
    /// A program that ran at least this long, or exited cleanly, works with its backend. The first-run check in
    /// M4 refines this with a window check.
    public static let workingAfter: TimeInterval = 15

    let paths: AppPaths
    let host: [String: String]

    public init(paths: AppPaths, host: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.host = host
    }

    /// Everything up to starting the process. Throws `LaunchError` for games that can't run, before any
    /// bottle is made for them.
    public func prepare(_ game: GameRecord, runtime: RuntimeManifest.Runtime,
                        backend override: GraphicsBackend? = nil, verboseLog: Bool = false) async throws -> Prepared {
        let exe = URL(filePath: game.executable)
        guard FileManager.default.fileExists(atPath: exe.path) else { throw LaunchError.missingExecutable(exe.path) }
        let info = try ExecutableInfo.read(exe)
        if info.format == .dos { throw LaunchError.dosProgram }
        let attempts: [GraphicsBackend]
        switch BackendPlan.forTraits(info.traits) {
        case let .attempts(list): attempts = list
        case let .unsupported(reason): throw LaunchError.unsupported(reason)
        }
        let backend = override ?? game.backend ?? attempts[0]

        guard let runtimeFolder = RuntimeInstaller(paths: paths).installed(runtime) else {
            throw BottleError.runtimeMissing(runtime.id)
        }
        let bottle = try await BottleManager(paths: paths, host: host)
            .ensureBottle(for: game.id, runtime: runtime, windows: game.windowsVersion)
        // Retina only for games that say they handle high DPI; others would draw a tiny interface.
        try BottleManager.setRegistryString(bottle: bottle, key: #"Software\Wine\Mac Driver"#, name: "RetinaMode",
                                            value: info.dpiAware ? "y" : "n")
        let wine = try BackendTree.wine(for: backend, runtimeFolder: runtimeFolder)
        try BackendTree.prepareBottle(bottle, for: backend, wine: wine)
        let environment = WineEnvironment.make(host: host, bottle: bottle.path, verboseLog: verboseLog)
        return Prepared(game: game, info: info, backend: backend, bottle: bottle, wine: wine,
                        environment: environment, log: newLogFile(for: game.id))
    }

    /// Runs the prepared game until everything in its bottle has exited.
    /// - Parameter started: called once the process is running, with something that can stop it.
    public func run(_ prepared: Prepared, started: @Sendable (GameSession) -> Void = { _ in }) async throws
        -> Outcome {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: prepared.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: prepared.log.path, contents: nil)
        let log = try FileHandle(forWritingTo: prepared.log)
        defer { try? log.close() }

        let startedAt = Date()
        let header = [
            "[ExePort] Launch \(ISO8601DateFormatter().string(from: startedAt))",
            "[ExePort] Game \(prepared.game.name) (\(prepared.game.id))",
            "[ExePort] Executable \(prepared.game.executable)",
            "[ExePort] Backend \(prepared.backend.rawValue)",
            "[ExePort] Windows \(prepared.game.windowsVersion.wineValue)",
            "[ExePort] Retina \(prepared.info.dpiAware ? "on" : "off")",
            "[ExePort] Wine \(prepared.wine.root.path(percentEncoded: false))",
            "[ExePort] WINEDEBUG=\(prepared.environment["WINEDEBUG"] ?? "")",
        ]
        log.write(Data((header.joined(separator: "\n") + "\n").utf8))

        let exe = URL(filePath: prepared.game.executable)
        let process = Process()
        process.executableURL = prepared.wine.wine
        process.arguments = [exe.path(percentEncoded: false)]
        process.currentDirectoryURL = exe.deletingLastPathComponent()
        process.environment = prepared.environment
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice

        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            started(GameSession(wine: prepared.wine, environment: prepared.environment))
        }
        let processDuration = Date().timeIntervalSince(startedAt)
        // The game may live on after `wine` returns (launchers); it's over when the bottle's server is.
        _ = try? await ProcessRunner.run(prepared.wine.wineserver.path, ["-w"], environment: prepared.environment)

        let duration = Date().timeIntervalSince(startedAt)
        let footer = "[ExePort] Exit \(exitCode) after \(Int(processDuration)) s, bottle idle after \(Int(duration)) s"
        log.write(Data((footer + "\n").utf8))
        pruneLogs(for: prepared.game.id)
        return Outcome(exitCode: exitCode, duration: duration, processDuration: processDuration,
                       backend: prepared.backend, log: prepared.log)
    }

    public func logsFolder(for game: GameID) -> URL { paths.logs(forGame: game) }

    private func newLogFile(for game: GameID) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return paths.logs(forGame: game).appending(path: "\(formatter.string(from: Date())).log")
    }

    private func pruneLogs(for game: GameID) {
        let folder = paths.logs(forGame: game)
        let logs = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".log") }
            .sorted()
        for name in logs.dropLast(Self.keptLogs) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }
}

extension GameLauncher.Outcome {
    /// Whether this run shows the backend works for the game.
    public var worked: Bool { exitCode == 0 || processDuration >= GameLauncher.workingAfter }
}

/// A running game, as far as stopping it goes.
public struct GameSession: Sendable {
    let wine: Wine
    let environment: [String: String]

    /// Ends everything in the game's bottle, like closing a hung game from Task Manager.
    public func stop() async {
        _ = try? await ProcessRunner.run(wine.wineserver.path, ["-k"], environment: environment)
    }
}

public enum LaunchError: Error, Equatable, CustomStringConvertible {
    case missingExecutable(String)
    case unsupported(BackendPlan.Reason)
    case dosProgram

    public var description: String {
        switch self {
        case let .missingExecutable(path):
            "The game's file isn't there any more: \(path). "
                + "It may have been moved or deleted, or its disk isn't connected."
        case .unsupported(.directX12):
            "This game needs DirectX 12, which ExePort doesn't support yet."
        case .unsupported(.sixteenBit):
            "This is a 16-bit Windows program. Macs can't run those."
        case .dosProgram:
            "This is a DOS program. It needs DOSBox rather than Windows."
        }
    }
}

extension BottleManager {
    /// Sets a string in the bottle's `user.reg`, writing only if it changes. Only while the bottle is idle.
    static func setRegistryString(bottle: URL, key: String, name: String, value: String) throws {
        let userReg = bottle.appending(path: "user.reg")
        let text = try String(contentsOf: userReg, encoding: .utf8)
        guard WineRegistry.string(in: text, key: key, name: name) != value else { return }
        try WineRegistry.setString(in: text, key: key, name: name, value: value)
            .write(to: userReg, atomically: true, encoding: .utf8)
    }
}
