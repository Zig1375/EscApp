import Foundation

/// Starts a game the way the app and `escapp run` both do, and waits until it is fully closed.
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
        /// How many times larger Wine draws the game's window (`GameScaling`).
        public var scale: Double = 1
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
    /// For past runs, where nothing but the log is left: a program that ran at least this long, or exited
    /// cleanly, worked with its backend. A launch itself decides with `AttemptJudge`, which also sees windows.
    public static let workingAfter: TimeInterval = 15

    let paths: AppPaths
    let host: [String: String]

    public init(paths: AppPaths, host: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.host = host
    }

    /// Everything up to starting the process. Throws `LaunchError` for games that can't run, before any
    /// bottle is made for them.
    /// What `prepare` is doing, for the "getting the game ready" sheet.
    public enum Step: Sendable, Equatable {
        /// Making the game's Windows; `firstTime` when the runtime's template must be built first (~30 s, once).
        case windows(WindowsVersion, firstTime: Bool)
        case graphics(GraphicsBackend, directX: ExecutableTraits.DirectX?)
        /// Everything is ready; Wine is being started.
        case starting
    }

    public func prepare(_ game: GameRecord, runtime: RuntimeManifest.Runtime,
                        backend override: GraphicsBackend? = nil, verboseLog: Bool = false,
                        progress: @Sendable (Step) -> Void = { _ in }) async throws -> Prepared {
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
        let bottles = BottleManager(paths: paths, host: host)
        progress(.windows(game.windowsVersion, firstTime: !bottles.hasTemplate(for: runtime)))
        let bottle = try await bottles.ensureBottle(for: game.id, runtime: runtime, windows: game.windowsVersion)
        progress(.graphics(backend, directX: info.directX.max()))
        // Wine's own "the program has crashed" dialog (winedbg) would pop up over the Mac; EscApp reports
        // crashes itself, from the log.
        try BottleManager.disableCrashDialog(bottle: bottle)
        // Retina only for games that say they handle high DPI; others would draw a tiny interface.
        try BottleManager.setRegistryString(bottle: bottle, key: #"Software\Wine\Mac Driver"#, name: "RetinaMode",
                                            value: info.dpiAware ? "y" : "n")
        let scale = try applyScaling(for: game, dpiAware: info.dpiAware, bottle: bottle)
        let wine = try BackendTree.wine(for: backend, runtimeFolder: runtimeFolder)
        try BackendTree.prepareBottle(bottle, for: backend, wine: wine)
        try await insertDisc(of: game, into: bottle)
        let environment = WineEnvironment.make(host: host, bottle: bottle.path, verboseLog: verboseLog)
        progress(.starting)
        return Prepared(game: game, info: info, backend: backend, bottle: bottle, wine: wine,
                        environment: environment, log: newLogFile(for: game.id), scale: scale)
    }

    /// Full-screen games get an emulated display mode, small windowed ones a system DPI that enlarges them
    /// (`GameScaling`). The key is the X11 driver's by name, but Wine's core reads it for every driver.
    private func applyScaling(for game: GameRecord, dpiAware: Bool, bottle: URL) throws -> Double {
        try BottleManager.setRegistryString(bottle: bottle, key: #"Software\Wine\X11 Driver"#, name: "EmulateModeset",
                                            value: "y")
        let scale = GameScaling.scale(setting: game.scaling ?? .auto, learned: game.window, dpiAware: dpiAware,
                                      screen: GameScaling.availableScreen())
        try BottleManager.setRegistryDWord(bottle: bottle, key: #"Control Panel\Desktop"#, name: "LogPixels",
                                           value: UInt32(GameScaling.dpi(for: scale)))
        return scale
    }

    /// A game installed from a CD that checks for it gets its disc image in drive `D:`; any other game an empty
    /// drive. The image stays attached until the game ends (`AutoLaunch` detaches it).
    private func insertDisc(of game: GameRecord, into bottle: URL) async throws {
        guard let path = game.disc else {
            DiscDrive.eject(from: bottle)
            return
        }
        let image = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: image.path) else { throw DiscError.missing(path) }
        try DiscDrive.insert(try await DiscImage.attach(image, paths: paths), into: bottle)
    }

    /// Runs the prepared game until everything in its bottle has exited.
    /// - Parameter started: called once the process is running, with something that can stop it.
    public func run(_ prepared: Prepared, started: @Sendable (GameSession) -> Void = { _ in }) async throws
        -> Outcome {
        let running = try start(prepared)
        started(running.session)
        return await running.finish()
    }

    /// Starts the prepared game and returns at once; `RunningGame.finish` waits for the end.
    public func start(_ prepared: Prepared) throws -> RunningGame {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: prepared.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: prepared.log.path, contents: nil)
        let log = try FileHandle(forWritingTo: prepared.log)
        defer { try? log.close() }

        let startedAt = Date()
        let header = [
            "[EscApp] Launch \(ISO8601DateFormatter().string(from: startedAt))",
            "[EscApp] Game \(prepared.game.name) (\(prepared.game.id))",
            "[EscApp] Executable \(prepared.game.executable)",
            "[EscApp] Backend \(prepared.backend.rawValue)",
            "[EscApp] Windows \(prepared.game.windowsVersion.wineValue)",
            "[EscApp] Retina \(prepared.info.dpiAware ? "on" : "off")",
            "[EscApp] Scale \(prepared.scale.formatted(.number.precision(.fractionLength(0...2))))x",
            "[EscApp] Wine \(prepared.wine.root.path(percentEncoded: false))",
            "[EscApp] WINEDEBUG=\(prepared.environment["WINEDEBUG"] ?? "")",
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

        let exit = ProcessExit()
        process.terminationHandler = { exit.exited($0.terminationStatus) }
        try process.run()
        let session = GameSession(wine: prepared.wine, environment: prepared.environment,
                                  processID: process.processIdentifier, scale: prepared.scale)
        return RunningGame(prepared: prepared, session: session, startedAt: startedAt, process: exit) { [self] in
            pruneLogs(for: $0)
        }
    }

    public func logsFolder(for game: GameID) -> URL { paths.logs(forGame: game) }

    private func newLogFile(for game: GameID) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return paths.logs(forGame: game).appending(path: "\(formatter.string(from: Date())).log")
    }

    func pruneLogs(for game: GameID) {
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
    public let environment: [String: String]
    /// The `wine` process started for the game. The game's own windows may belong to it or to processes it
    /// starts, all running Wine's binaries.
    public let processID: Int32
    /// How many times larger Wine draws the game, to tell its own size from its window on the Mac.
    public var scale: Double = 1

    /// Wine's folder: any process running from inside it belongs to this game's session.
    public var wineRoot: URL { wine.root }

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
            "This game needs DirectX 12, which EscApp doesn't support yet."
        case .unsupported(.sixteenBit):
            "This is a 16-bit Windows program. Macs can't run those."
        case .dosProgram:
            "This is a DOS program. It needs DOSBox rather than Windows."
        }
    }
}

extension BottleManager {
    static func disableCrashDialog(bottle: URL) throws {
        let userReg = bottle.appending(path: "user.reg")
        let text = try String(contentsOf: userReg, encoding: .utf8)
        let key = #"Software\Wine\WineDbg"#
        guard !WineRegistry.contains(text, key: key, entry: #""ShowCrashDialog"=dword:00000000"#) else { return }
        try WineRegistry.setDWord(in: text, key: key, name: "ShowCrashDialog", value: 0)
            .write(to: userReg, atomically: true, encoding: .utf8)
    }

    /// Sets a DWORD in the bottle's `user.reg`, writing only if it changes. Only while the bottle is idle.
    static func setRegistryDWord(bottle: URL, key: String, name: String, value: UInt32) throws {
        let userReg = bottle.appending(path: "user.reg")
        let text = try String(contentsOf: userReg, encoding: .utf8)
        let hex = String(value, radix: 16)
        let entry = "\"\(name)\"=dword:\(String(repeating: "0", count: 8 - hex.count))\(hex)"
        guard !WineRegistry.contains(text, key: key, entry: entry) else { return }
        try WineRegistry.setDWord(in: text, key: key, name: name, value: value)
            .write(to: userReg, atomically: true, encoding: .utf8)
    }

    /// Sets a string in the bottle's `user.reg` (or `system.reg`, for keys under HKLM), writing only if it
    /// changes. Only while the bottle is idle.
    static func setRegistryString(bottle: URL, key: String, name: String, value: String,
                                  file: String = "user.reg") throws {
        let userReg = bottle.appending(path: file)
        let text = try String(contentsOf: userReg, encoding: .utf8)
        guard WineRegistry.string(in: text, key: key, name: name) != value else { return }
        try WineRegistry.setString(in: text, key: key, name: name, value: value)
            .write(to: userReg, atomically: true, encoding: .utf8)
    }
}
