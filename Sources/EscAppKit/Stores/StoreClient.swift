import Foundation

/// Installs, opens, closes and removes a store's Windows client in its own bottle (Stores.dc.html), and keeps it
/// running in the Wine tree a game needs (`prepareForGame`).
public struct StoreClient: Sendable {
    /// What an install is doing, for the progress row.
    public enum Step: Sendable, Equatable {
        case downloading(received: Int64, total: Int64?)
        /// The store's installer runs; one without silent arguments shows its own window.
        case installing
        /// The client downloads its current version after installing (Steam's ~240 MB, in kilobytes as its log
        /// counts them).
        case updating(received: Int64?, total: Int64?)
    }

    let paths: AppPaths
    let host: [String: String]

    public init(paths: AppPaths, host: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.host = host
    }

    public func bottle(for store: Store) -> URL { paths.bottle(forGame: store.bottleID) }

    public func isInstalled(_ store: Store) -> Bool { store.client(in: bottle(for: store)) != nil }

    /// Whether anything runs in the store's bottle: its client, or one of its games.
    public func isRunning(_ store: Store) -> Bool { !WineProcesses.running(in: bottle(for: store)).isEmpty }
    /// What the client asks the player in its own window before it starts the game `storeID` (`StoreModule.question`).
    public func question(_ store: Store, storeID: String) -> String? {
        store.module.question(bottle: bottle(for: store), storeID: storeID)
    }

    /// "Install": the bottle, the publisher's installer, then what the client needs before it opens (Steam's
    /// first update). Throws when the client isn't there afterwards (the player closed its setup window, say).
    public func install(_ store: Store, runtime: RuntimeManifest.Runtime,
                        progress: @escaping @Sendable (Step) -> Void = { _ in }) async throws {
        let bottle = try await BottleManager(paths: paths, host: host).ensureBottle(for: store.bottleID,
                                                                                    runtime: runtime)
        try BottleManager.disableCrashDialog(bottle: bottle)
        // Inside the bottle under a short name: Epic's package overflows a buffer with a long path
        // (`Z:\Users\…\Downloads\Stores\EpicGamesLauncherInstaller.msi` crashed it, `C:\…\setup.msi` doesn't).
        let folder = bottle.appending(path: "drive_c/windows/temp", directoryHint: .isDirectory)
        let setup = store.module.installer
        let name = "escapp-setup." + setup.url.pathExtension
        let installer = folder.appending(path: name)
        try await StoreDownload.fetch(setup.url, to: installer) {
            progress(.downloading(received: $0, total: $1))
        }
        defer { try? FileManager.default.removeItem(at: installer) }
        guard Self.isInstaller(installer, package: setup.isPackage) else {
            throw StoreError.notAnInstaller(store.name)
        }

        progress(.installing)
        let wine = try plainWine(runtime)
        let environment = WineEnvironment.make(host: host, bottle: bottle.path, extra: store.environment,
                                               fastSync: WineEnvironment.fastSync(for: nil, wine: wine))
        let windowsPath = #"C:\windows\temp\"# + name
        let arguments = setup.isPackage
            ? ["msiexec", "/i", windowsPath] + setup.arguments
            : [windowsPath] + setup.arguments
        _ = try await Self.run(wine, arguments, in: folder, environment: environment, log: newLog(store, "install"))
        // Installers hand their work to other processes and exit: done is when the bottle is quiet.
        _ = try? await ProcessRunner.run(wine.wineserver.path, ["-w"], environment: environment)
        guard let client = store.client(in: bottle) else { throw StoreError.notInstalled(store.name) }
        try await store.module.finishInstall(self, client: client, wine: wine, environment: environment,
                                             progress: progress)
    }

    /// "Open Steam": starts the client, or asks the running one to show its window.
    /// - Parameter uninstalling: opens it on removing this game of its own.
    public func open(_ store: Store, runtime: RuntimeManifest.Runtime, uninstalling storeID: String? = nil)
        async throws {
        guard let client = store.client(in: bottle(for: store)) else { throw StoreError.notInstalled(store.name) }
        // A client running with its vendor's helper shows a black window, and asking it to come forward only
        // brings that back. It happens after Steam updated itself while running, or when EscApp quit halfway
        // through installing it. Restarted, it gets the wrapper.
        if isRunning(store), ChromiumHelper.needsWrapping(store, in: bottle(for: store)) { await shutDown(store) }
        let wine = try await prepare(store, runtime: runtime, wine: runningWine(store) ?? defaultWine(runtime))
        let extra = storeID.map { store.uninstallArguments(storeID: $0) } ?? []
        try start(wine, client, store.clientArguments(in: bottle(for: store)) + extra, store: store)
        store.module.opened(self, client: client, wine: wine)
    }

    /// Gets the store's bottle ready to start one of its games with `wine` (the game's graphics backend): a
    /// client running in another Wine tree is closed first, since everything in a bottle shares one tree.
    /// So is a client running in Retina mode when the game doesn't handle high DPI: Wine then halved the mouse
    /// position for it, and none of Banished's buttons could be clicked.
    /// Returns whether the bottle was idle, so the game's settings could be written into its registry.
    public func prepareForGame(_ store: Store, wine: Wine, retina: Bool) async throws -> Bool {
        if let running = runningWine(store) {
            let sameTree = running.root.standardized == wine.root.standardized
            guard !sameTree || Self.runsRetina(bottle(for: store)) && !retina else { return false }
            await shutDown(store)
        }
        _ = try await prepare(store, runtime: nil, wine: wine)
        return true
    }

    /// The command line that starts a game through the client.
    public func playCommand(_ store: Store, storeID: String) throws -> (url: URL, arguments: [String]) {
        guard let client = store.client(in: bottle(for: store)) else { throw StoreError.notInstalled(store.name) }
        return (client, store.clientArguments(in: bottle(for: store)) + store.playArguments(storeID: storeID))
    }

    /// Closes the client and everything else in its bottle. A client that can be asked to quit is asked first
    /// (`StoreModule.askToQuit`), so it saves its state. Nothing here waits on Wine without a limit: a Steam
    /// stuck at start never answered `-shutdown`, and its `steam.exe` even outlived `wineserver -k`, so what is
    /// left at the end is killed.
    /// - Parameter sparing: checked before the bottle's Wine is ended; true stops there, leaving what runs.
    ///   `StoreKeeper` quits an idle client this way: a game started while Steam was asked to quit (Banished, 11 s
    ///   into it) was killed with the rest.
    public func shutDown(_ store: Store, sparing: (@Sendable () -> Bool)? = nil) async {
        guard let wine = runningWine(store) else { return }
        let environment = WineEnvironment.make(host: host, bottle: bottle(for: store).path,
                                               fastSync: WineEnvironment.fastSync(for: nil, wine: wine))
        if let client = store.client(in: bottle(for: store)) {
            await store.module.askToQuit(self, client: client, bottle: bottle(for: store), wine: wine,
                                         environment: environment)
        }
        if let sparing, sparing() { return }
        _ = try? await ProcessRunner.run(wine.wineserver.path, ["-k"], environment: environment, timeout: 10)
        _ = try? await ProcessRunner.run(wine.wineserver.path, ["-w"], environment: environment, timeout: 10)
        await Self.killLeftovers(in: bottle(for: store))
    }

    /// Kills whatever still runs in `bottle` and waits up to 5 s for it to go.
    static func killLeftovers(in bottle: URL) async {
        for process in WineProcesses.running(in: bottle) { kill(process.pid, SIGKILL) }
        let deadline = Date().addingTimeInterval(5)
        while !WineProcesses.running(in: bottle).isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// "Remove…": the client and its bottle go, with every game installed through it. Saves in the shared
    /// profile stay.
    public func uninstall(_ store: Store) async throws {
        await shutDown(store)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: paths.logs(forGame: store.bottleID))
        if fileManager.fileExists(atPath: bottle(for: store).path) {
            try fileManager.removeItem(at: bottle(for: store))
        }
        try StoreLibrary.sync(paths: paths)
    }

    // MARK: Wine

    /// The Wine tree the store's bottle runs in now, if it runs.
    func runningWine(_ store: Store) -> Wine? {
        WineProcesses.running(in: bottle(for: store)).lazy.compactMap { WineProcesses.wineTree(of: $0.executable) }
            .first { FileManager.default.fileExists(atPath: $0.appending(path: "bin/wineserver").path) }
            .map { Wine(root: $0) }
    }

    /// Clients start with DXVK, which suits the Chromium they draw with.
    private func defaultWine(_ runtime: RuntimeManifest.Runtime) throws -> Wine {
        guard let folder = RuntimeInstaller(paths: paths).installed(runtime) else {
            throw BottleError.runtimeMissing(runtime.id)
        }
        return try BackendTree.wine(for: .dxvk, runtimeFolder: folder)
    }

    private func plainWine(_ runtime: RuntimeManifest.Runtime) throws -> Wine {
        guard let folder = RuntimeInstaller(paths: paths).installed(runtime) else {
            throw BottleError.runtimeMissing(runtime.id)
        }
        return Wine(runtimeFolder: folder)
    }

    /// Before the client starts: Chromium helpers wrapped, while nothing runs in the bottle.
    private func prepare(_ store: Store, runtime: RuntimeManifest.Runtime?, wine: Wine) async throws -> Wine {
        if !isRunning(store) {
            if let runtime { try await BottleManager(paths: paths, host: host).ensureBottle(for: store.bottleID,
                                                                                            runtime: runtime) }
            try ChromiumHelper.wrap(store, in: bottle(for: store))
            try Self.drawSharp(bottle(for: store))
            try Self.setUpForGames(bottle(for: store))
            await store.module.prepareToStart(self, bottle: bottle(for: store), wine: wine)
        }
        return wine
    }

    /// Starts the client in the background; it outlives this call and EscApp's window.
    func start(_ wine: Wine, _ client: URL, _ arguments: [String], store: Store) throws {
        let log = newLog(store, "client")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        handle.write(Data(LogHeader.text(wine: wine).utf8))
        let process = Process()
        process.executableURL = wine.wine
        process.arguments = [client.path(percentEncoded: false)] + arguments
        process.currentDirectoryURL = client.deletingLastPathComponent()
        process.environment = WineEnvironment.make(host: host, bottle: bottle(for: store).path,
                                                   extra: store.environment,
                                                   fastSync: WineEnvironment.fastSync(for: nil, wine: wine))
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }

    func newLog(_ store: Store, _ kind: String) -> URL {
        let folder = paths.logs(forGame: store.bottleID)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Room for this one: a client writes a log each time it starts, and they piled up by the dozen.
        LogRotation.prune(folder, keep: LogRotation.kept - 1)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return folder.appending(path: "\(kind)-\(formatter.string(from: Date())).log")
    }

    /// Runs Wine with its output in `log`, waits for that process and returns its exit code.
    static func run(_ wine: Wine, _ arguments: [String], in folder: URL, environment: [String: String],
                    log: URL) async throws -> Int32 {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        handle.write(Data((LogHeader.text(wine: wine) + "[EscApp] Run \(arguments.joined(separator: " "))\n").utf8))
        let process = Process()
        process.executableURL = wine.wine
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = folder
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        handle.write(Data("[EscApp] Exit \(status)\n".utf8))
        return status
    }

    /// A Windows program, or for a package a Windows Installer file (an OLE compound file).
    static func isInstaller(_ file: URL, package: Bool) -> Bool {
        if package {
            let header = (try? FileHandle(forReadingFrom: file)).flatMap { try? $0.read(upToCount: 8) }
            return header == Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        }
        guard let info = try? ExecutableInfo.read(file) else { return false }
        return info.format == .pe32 || info.format == .pe64
    }
}

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case download(status: Int)
    case notAnInstaller(String)
    case notInstalled(String)
    case updateFailed(Int32)

    public var description: String {
        switch self {
        case let .download(status): "The store's server answered with error \(status). Try again later."
        case let .notAnInstaller(name): "What came from \(name)'s site isn't its installer, so EscApp didn't run it."
        case let .notInstalled(name): "\(name) isn't installed. Its setup may have been closed before it finished."
        case let .updateFailed(status):
            "Steam couldn't download its update (it stopped with code \(status)). Check the connection and try again."
        }
    }
}

/// Downloads a store's installer with progress. Unlike runtime components there is no checksum to check: the
/// publishers replace these files with each release.
enum StoreDownload {
    static func fetch(_ url: URL, to file: URL,
                      progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let delegate = Delegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw StoreError.download(status: status)
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, Sendable {
        let progress: @Sendable (Int64, Int64?) -> Void

        init(progress: @escaping @Sendable (Int64, Int64?) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
    }
}
