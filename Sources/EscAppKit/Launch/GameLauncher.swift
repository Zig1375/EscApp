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
        /// Whether Wine draws the game in Retina mode (`GameSettings.retina`).
        public var retina = false
        /// A store game: the store's client and what makes it start the game. Nil starts the exe itself.
        public var client: (url: URL, arguments: [String])?
        /// A store game's folder as Windows sees it, which tells its processes from the client's.
        public var gameFolder: String?
        /// Chromium's switches for a program built on it (`ChromiumApp`).
        public var chromium: ChromiumApp.Mode?
        /// The store whose client this program is, installed by its own installer rather than from Stores.
        public var storeClient: Store?
        /// The language Windows has for the game when it isn't the Mac's (`GameLanguage`).
        public var locale: String?
        /// RPG Maker packages linked into the bottle, as `engine/name` (`RTPInstaller`).
        public var rtps: [String] = []
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
        /// Downloading files the game needs and Windows doesn't have (RPG Maker's packages), in bytes.
        case gameFiles(received: Int64, total: Int64)
        /// Everything is ready; Wine is being started.
        case starting
    }

    /// A store game's client, made ready for it, and the command that starts the game through the client.
    /// Returns whether the bottle was idle; always for a game without a store.
    private func prepareStore(for game: GameRecord, wine: Wine, retina: Bool) async throws
        -> (idle: Bool, client: (url: URL, arguments: [String])?) {
        guard let store = game.store else { return (true, nil) }
        let stores = StoreClient(paths: paths, host: host)
        let idle = try await stores.prepareForGame(store, wine: wine, retina: retina)
        guard store.launchesGames, let id = game.storeID else { return (idle, nil) }
        return (idle, try stores.playCommand(store, storeID: id))
    }

    /// - Parameter fetchGameFiles: false leaves out downloads (`gameFiles`): warming a bottle on hover mustn't
    ///   start a 200 MB download. What is installed already is linked either way.
    public func prepare(_ game: GameRecord, runtime: RuntimeManifest.Runtime,
                        backend override: GraphicsBackend? = nil, verboseLog: Bool = false,
                        fetchGameFiles: Bool = true,
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
        // A store game shares its store's bottle, and its Windows version.
        let bottle = try await bottles.ensureBottle(for: game.bottleID, runtime: runtime,
                                                    windows: game.store == nil ? game.windowsVersion : .default)
        let files = try await gameFiles(for: game, runtime: runtime, fetch: fetchGameFiles, progress: progress)
        progress(.graphics(backend, directX: info.directX.max()))
        let wine = try BackendTree.wine(for: backend, runtimeFolder: runtimeFolder)
        // Retina only for games that say they handle high DPI; others would draw a tiny interface.
        let retina = GameSettings.retina(game.retina, dpiAware: info.dpiAware)
        let (idle, client) = try await prepareStore(for: game, wine: wine, retina: retina)
        let fastSync = WineEnvironment.fastSync(for: game, wine: wine)
        if game.store == nil { await Self.stopWine(in: bottle, unless: fastSync) }
        // With the store's client already running in the right Wine, its registry can't be written: the game
        // keeps the settings the bottle had when the client started.
        let scale = idle ? try Self.configure(bottle: bottle, for: game, retina: retina,
                                              screen: GameScaling.availableScreen(), predicted: files.window) : 1
        try files.link(into: bottle, registry: idle)
        try BackendTree.prepareBottle(bottle, for: backend, wine: wine)
        try await insertDisc(of: game, into: bottle)
        let environment = WineEnvironment.make(host: host, bottle: bottle.path,
                                               extra: (game.store?.environment ?? [:])
                                                   .merging(GameSettings.environment(of: game)) { _, user in user },
                                               verboseLog: verboseLog || game.verboseLog == true,
                                               fastSync: fastSync, locale: files.locale)
        progress(.starting)
        let folder = game.store.map { _ in
            WindowsPath.windowsPath(of: URL(filePath: game.folder, directoryHint: .isDirectory), inBottle: bottle)
        }
        let storeClient = game.store == nil ? Store.clientProgram(exe, in: bottle) : nil
        if let storeClient { try await StoreClient(paths: paths, host: host).prepareClientProgram(storeClient,
                                                                                                    in: bottle,
                                                                                                    wine: wine) }
        let chromium = game.store != nil ? nil
            : game.chromium ?? (info.chromium ? .inProcessGPU : nil)
        return Prepared(game: game, info: info, backend: backend, bottle: bottle, wine: wine,
                        environment: environment, log: newLogFile(for: game.id), scale: scale, retina: retina,
                        client: client,
                        gameFolder: folder, chromium: chromium, storeClient: storeClient, locale: files.locale,
                        rtps: files.rtps.map { "\($0.rtp.engine)/\($0.rtp.name)" })
    }

    /// Ends what still runs in a game's bottle with osync the other way: the running wineserver decides, so the
    /// game's setting would otherwise not apply.
    /// Something EscApp started there without the game's settings (an installer, a bottle update) lingers for a
    /// few seconds after it finishes, and Wine keeps its server up that long.
    static func stopWine(in bottle: URL, unless fastSync: Bool) async {
        let running = WineProcesses.running(in: bottle)
        guard running.contains(where: { $0.fastSync != fastSync }) else { return }
        let trees = Set(running.compactMap { WineProcesses.wineTree(of: $0.executable) })
        for tree in trees {
            let wine = Wine(root: tree)
            guard FileManager.default.fileExists(atPath: wine.wineserver.path) else { continue }
            _ = try? await ProcessRunner.run(wine.wineserver.path, ["-k"],
                                             environment: ["WINEPREFIX": bottle.path(percentEncoded: false)])
        }
        let deadline = Date().addingTimeInterval(10)
        while !WineProcesses.running(in: bottle).isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Writes the game's settings into its bottle before a launch, each value only when it changes. Returns how
    /// many times larger Wine will draw the game. Only while the bottle's Wine is down (see `WineRegistry`).
    /// - Parameter predicted: the game's window known before it ever ran (`GameFiles.window`); what was seen on a
    ///   launch wins over it.
    static func configure(bottle: URL, for game: GameRecord, retina: Bool, screen: GameScaling.Size,
                          predicted: GameScaling.LearnedWindow? = nil) throws -> Double {
        // Wine's own "the program has crashed" dialog (winedbg) would pop up over the Mac; EscApp reports
        // crashes itself, from the log.
        try BottleManager.disableCrashDialog(bottle: bottle)
        try WindowsFonts.replaceJapaneseFonts(bottle: bottle)
        let macDriver = #"Software\Wine\Mac Driver"#
        try BottleManager.setRegistryString(bottle: bottle, key: macDriver, name: "RetinaMode",
                                            value: retina ? "y" : "n")
        let command = game.commandAsControl == true ? "y" : "n"
        for side in ["LeftCommandIsCtrl", "RightCommandIsCtrl"] {
            try BottleManager.setRegistryString(bottle: bottle, key: macDriver, name: side, value: command)
        }
        // Full-screen games get an emulated display mode, small windowed ones a system DPI that enlarges them
        // (`GameScaling`), and fixed-size windows can be stretched.
        try BottleManager.enableScaling(bottle: bottle)
        let scale = GameScaling.scale(setting: game.scaling ?? .auto, learned: game.window ?? predicted,
                                      dpiAware: retina, screen: screen)
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
        let retina = prepared.retina
        let header = Self.header(for: prepared, retina: retina, startedAt: startedAt)
        let ready = prepared.storeClient != .steam || StoreClient.steamReady(prepared.bottle)
        let arguments = (prepared.storeClient?.clientArguments(clientReady: ready) ?? [])
            + GameSettings.arguments(prepared.game.arguments ?? "")
            + (prepared.chromium?.arguments(forProgramIn: URL(filePath: prepared.game.executable)
                .deletingLastPathComponent()) ?? [])
        var extra = arguments.isEmpty ? [] : ["[EscApp] Arguments \(arguments.joined(separator: " "))"]
        if !prepared.rtps.isEmpty { extra.append("[EscApp] RPG Maker \(prepared.rtps.joined(separator: ", "))") }
        if let store = prepared.game.store {
            extra.append("[EscApp] Store \(store.name) \(prepared.game.storeID ?? "")")
        }
        log.write(Data(((header + extra).joined(separator: "\n") + "\n").utf8))

        let process = Self.process(for: prepared, arguments: arguments, log: log)
        let exit = ProcessExit()
        if let folder = prepared.gameFolder {
            // A store game is over when its own processes are; the client stays.
            let started = ProcessExit()
            process.terminationHandler = { started.exited($0.terminationStatus) }
            try process.run()
            StoreGameWatch.forgetStop(bottle: prepared.bottle, folder: folder)
            let steamApp = prepared.game.store == .steam ? prepared.game.storeID : nil
            StoreGameWatch(bottle: prepared.bottle, folder: folder, steamApp: steamApp)
                .watch(starter: started, game: exit) { [self] in await restartStuckSteam(prepared, arguments) }
        } else {
            process.terminationHandler = { exit.exited($0.terminationStatus) }
            try process.run()
            WindowKeeper.start(for: prepared)
        }
        // Points on the Mac per pixel of the game: the DPI enlarging, or with Retina on, half a point per pixel.
        let pointsPerPixel = retina ? 1 / GameScaling.backingScale() : prepared.scale
        let session = GameSession(wine: prepared.wine, environment: prepared.environment,
                                  processID: process.processIdentifier, scale: pointsPerPixel,
                                  gameFolder: prepared.gameFolder)
        return RunningGame(prepared: prepared, session: session, startedAt: startedAt, process: exit) { [self] in
            pruneLogs(for: $0)
        }
    }

    /// The log's first lines: what this launch is made of.
    private static func header(for prepared: Prepared, retina: Bool, startedAt: Date) -> [String] {
        [
            "[EscApp] Launch \(ISO8601DateFormatter().string(from: startedAt))",
            "[EscApp] Game \(prepared.game.name) (\(prepared.game.id))",
            "[EscApp] Executable \(prepared.game.executable)",
            "[EscApp] Backend \(prepared.backend.rawValue)",
            "[EscApp] Windows \(prepared.game.windowsVersion.wineValue)",
            "[EscApp] Retina \(retina ? "on" : "off")",
            "[EscApp] Scale \(prepared.scale.formatted(.number.precision(.fractionLength(0...2))))x",
            "[EscApp] Wine \(prepared.wine.root.path(percentEncoded: false))",
            "[EscApp] WINEDEBUG=\(prepared.environment["WINEDEBUG"] ?? "")",
            "[EscApp] osync \(WineEnvironment.fastSyncIsOn(prepared.environment) ? "on" : "off")",
            "[EscApp] Chromium \(prepared.chromium?.rawValue ?? "no")",
            "[EscApp] Language \(prepared.locale ?? "Mac's")",
        ]
    }

    /// Steam stuck at start (`SteamStartCheck`): closed, everything in its bottle killed, and the game started
    /// through it again. Returns the new starter, nil when it couldn't start.
    private func restartStuckSteam(_ prepared: Prepared, _ arguments: [String]) async -> ProcessExit? {
        await StoreClient(paths: paths, host: host).shutDown(.steam)
        guard let log = try? FileHandle(forWritingTo: prepared.log) else { return nil }
        defer { try? log.close() }
        _ = try? log.seekToEnd()
        log.write(Data("[EscApp] Steam was stuck at start; closed it and started the game again\n".utf8))
        let process = Self.process(for: prepared, arguments: arguments, log: log)
        let exit = ProcessExit()
        process.terminationHandler = { exit.exited($0.terminationStatus) }
        guard (try? process.run()) != nil else { return nil }
        return exit
    }

    /// `wine <exe> <arguments>` from the game's folder, or for a store game `wine <client> -applaunch <id> …`.
    private static func process(for prepared: Prepared, arguments: [String], log: FileHandle) -> Process {
        let exe = URL(filePath: prepared.game.executable)
        let process = Process()
        process.executableURL = prepared.wine.wine
        if let client = prepared.client {
            // Steam passes its own launch options on; the game's go after `-applaunch <id>`.
            process.arguments = [client.url.path(percentEncoded: false)] + client.arguments + arguments
            process.currentDirectoryURL = client.url.deletingLastPathComponent()
        } else {
            process.arguments = [exe.path(percentEncoded: false)] + arguments
            process.currentDirectoryURL = exe.deletingLastPathComponent()
        }
        process.environment = prepared.environment
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        return process
    }

    public func logsFolder(for game: GameID) -> URL { paths.logs(forGame: game) }

    private func newLogFile(for game: GameID) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return paths.logs(forGame: game).appending(path: "\(formatter.string(from: Date())).log")
    }

    func pruneLogs(for game: GameID) {
        LogRotation.prune(paths.logs(forGame: game))
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
    /// Points on the Mac per pixel of the game, to tell the game's own size from its window: the enlarging, or
    /// below 1 with Retina on.
    public var scale: Double = 1

    /// A store game's folder as Windows sees it: its processes, not the client's, are the game.
    public var gameFolder: String?

    /// Wine's folder: any process running from inside it belongs to this game's session.
    public var wineRoot: URL { wine.root }

    /// Ends everything in the game's bottle, like closing a hung game from Task Manager. For a store game only
    /// the game's own processes: the client keeps running.
    public func stop() async {
        if let gameFolder, let prefix = environment["WINEPREFIX"] {
            await StoreGameWatch(bottle: URL(filePath: prefix, directoryHint: .isDirectory), folder: gameFolder).stop()
            return
        }
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
