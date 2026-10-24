import Foundation

/// Installs, opens, closes and removes a store's Windows client in its own bottle (Stores.dc.html), and keeps it
/// running in the Wine tree a game needs (`prepareForGame`).
public struct StoreClient: Sendable {
    /// What an install is doing, for the progress row.
    public enum Step: Sendable, Equatable {
        case downloading(received: Int64, total: Int64?)
        /// The store's installer runs; GOG's and EA's show their own window.
        case installing
        /// Steam downloads its client on its first start (~240 MB), in kilobytes as its log counts them.
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

    /// "Install": the bottle, the publisher's installer, then for Steam its first update. Throws when the
    /// client isn't there afterwards (the player closed GOG's or EA's setup window, say).
    public func install(_ store: Store, runtime: RuntimeManifest.Runtime,
                        progress: @escaping @Sendable (Step) -> Void = { _ in }) async throws {
        let bottle = try await BottleManager(paths: paths, host: host).ensureBottle(for: store.bottleID,
                                                                                    runtime: runtime)
        try BottleManager.disableCrashDialog(bottle: bottle)
        // Inside the bottle under a short name: Epic's package overflows a buffer with a long path
        // (`Z:\Users\…\Downloads\Stores\EpicGamesLauncherInstaller.msi` crashed it, `C:\…\setup.msi` doesn't).
        let folder = bottle.appending(path: "drive_c/windows/temp", directoryHint: .isDirectory)
        let name = "escapp-setup." + store.installerURL.pathExtension
        let installer = folder.appending(path: name)
        try await StoreDownload.fetch(store.installerURL, to: installer) {
            progress(.downloading(received: $0, total: $1))
        }
        defer { try? FileManager.default.removeItem(at: installer) }
        guard Self.isInstaller(installer, package: store.installerIsPackage) else {
            throw StoreError.notAnInstaller(store.name)
        }

        progress(.installing)
        let wine = try plainWine(runtime)
        let environment = WineEnvironment.make(host: host, bottle: bottle.path, extra: store.environment,
                                               msync: WineEnvironment.msync(for: nil, wine: wine))
        let windowsPath = #"C:\windows\temp\"# + name
        let arguments = store.installerIsPackage
            ? ["msiexec", "/i", windowsPath] + store.installerArguments
            : [windowsPath] + store.installerArguments
        _ = try await Self.run(wine, arguments, in: folder, environment: environment, log: newLog(store, "install"))
        // Installers hand their work to other processes and exit: done is when the bottle is quiet.
        _ = try? await ProcessRunner.run(wine.wineserver.path, ["-w"], environment: environment)
        guard let client = store.client(in: bottle) else { throw StoreError.notInstalled(store.name) }

        if store == .steam, !Self.steamReady(bottle) {
            progress(.updating(received: nil, total: nil))
            try await updateSteam(client, wine: wine, environment: environment, progress: progress)
        }
        if store == .epic {
            progress(.updating(received: nil, total: nil))
            try await updateEpic(client, wine: wine, environment: environment)
        }
    }

    /// Steam's installer only puts down a bootstrapper. Its first start downloads the client in two rounds,
    /// each ending with Steam restarting itself: an older 32-bit client first, then the current 64-bit one.
    /// Once the second round is in, Steam is stopped before its window opens: that start would run its web
    /// helper unwrapped and show a black window. The next "Open Steam" starts it wrapped.
    func updateSteam(_ client: URL, wine: Wine, environment: [String: String], in bottle: URL? = nil,
                     progress: @escaping @Sendable (Step) -> Void) async throws {
        let bottle = bottle ?? self.bottle(for: .steam)
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

    /// "Open Steam": starts the client, or asks the running one to show its window.
    /// - Parameter uninstalling: opens it on removing this game of its own.
    public func open(_ store: Store, runtime: RuntimeManifest.Runtime, uninstalling storeID: String? = nil)
        async throws {
        guard let client = store.client(in: bottle(for: store)) else { throw StoreError.notInstalled(store.name) }
        let wine = try await prepare(store, runtime: runtime, wine: runningWine(store) ?? defaultWine(runtime))
        let extra = storeID.map { store.uninstallArguments(storeID: $0) } ?? []
        try start(wine, client, store.clientArguments(clientReady: clientReady(store)) + extra, store: store)
        if store == .epic { watchEpicUpdates(client, wine: wine) }
    }

    /// Gets the store's bottle ready to start one of its games with `wine` (the game's graphics backend): a
    /// client running in another Wine tree is closed first, since everything in a bottle shares one tree.
    /// Returns whether the bottle was idle, so the game's settings could be written into its registry.
    public func prepareForGame(_ store: Store, wine: Wine) async throws -> Bool {
        if let running = runningWine(store) {
            guard running.root.standardized != wine.root.standardized else { return false }
            await shutDown(store)
        }
        _ = try await prepare(store, runtime: nil, wine: wine)
        return true
    }

    /// The command line that starts a game through the client.
    public func playCommand(_ store: Store, storeID: String) throws -> (url: URL, arguments: [String]) {
        guard let client = store.client(in: bottle(for: store)) else { throw StoreError.notInstalled(store.name) }
        return (client, store.clientArguments(clientReady: clientReady(store)) + store.playArguments(storeID: storeID))
    }

    /// Closes the client and everything else in its bottle. Steam is asked to quit first, so it saves its
    /// state; whatever is still running 20 s later is ended.
    public func shutDown(_ store: Store) async {
        guard let wine = runningWine(store) else { return }
        let environment = WineEnvironment.make(host: host, bottle: bottle(for: store).path,
                                               msync: WineEnvironment.msync(for: nil, wine: wine))
        if store == .steam, let client = store.client(in: bottle(for: store)) {
            _ = try? await ProcessRunner.run(wine.wine.path, [client.path(percentEncoded: false), "-shutdown"],
                                             environment: environment)
            let deadline = Date().addingTimeInterval(20)
            while isRunning(store), Date() < deadline { try? await Task.sleep(for: .milliseconds(500)) }
        }
        _ = try? await ProcessRunner.run(wine.wineserver.path, ["-k"], environment: environment)
        _ = try? await ProcessRunner.run(wine.wineserver.path, ["-w"], environment: environment)
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
            if store == .epic, Self.epicHasStagedUpdate(bottle(for: store)) { await applyEpicUpdate(wine: wine) }
        }
        return wine
    }

    private func clientReady(_ store: Store) -> Bool {
        store != .steam || Self.steamReady(bottle(for: store))
    }

    /// Starts the client in the background; it outlives this call and EscApp's window.
    func start(_ wine: Wine, _ client: URL, _ arguments: [String], store: Store) throws {
        let log = newLog(store, "client")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = wine.wine
        process.arguments = [client.path(percentEncoded: false)] + arguments
        process.currentDirectoryURL = client.deletingLastPathComponent()
        process.environment = WineEnvironment.make(host: host, bottle: bottle(for: store).path,
                                                   extra: store.environment,
                                                   msync: WineEnvironment.msync(for: nil, wine: wine))
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }

    func newLog(_ store: Store, _ kind: String) -> URL {
        let folder = paths.logs(forGame: store.bottleID)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
        handle.write(Data("[EscApp] Run \(arguments.joined(separator: " "))\n".utf8))
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
