import Foundation

/// Installs Microsoft's runtimes (`RuntimeManifest.Redist`) into a game's bottle, the way the game's own
/// prerequisites would on Windows: Microsoft's installer, run silently.
///
/// Unlike RPG Maker's packages they go into each bottle that needs them rather than one shared folder: they put
/// DLLs into Windows' own folders and register themselves, which only works inside the Windows they serve. The
/// bottle's `REDISTS.json` records what Magic Kettle installed, and what failed, so a broken installer runs once per
/// download rather than on every launch.
public struct RedistInstaller: Sendable {
    public static let markerName = "REDISTS.json"

    public struct Marker: Codable, Sendable, Equatable {
        public struct Entry: Codable, Sendable, Equatable {
            public var id: String
            public var version: String
            public var sha256: String
        }

        public var installed: [Entry] = []
        /// Installers that ran to the end and left nothing behind.
        public var failed: [Entry] = []
    }

    /// Where an install is.
    public enum Phase: Sendable, Equatable {
        case downloading(received: Int64, total: Int64)
        case installing
    }

    /// Exit codes that mean done: 3010 and 1641 ask for a restart Wine doesn't need, 1638 found a newer version.
    static let successCodes: Set<Int32> = [0, 1638, 1641, 3010]

    let paths: AppPaths
    let host: [String: String]

    public init(paths: AppPaths, host: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.host = host
    }

    // MARK: - What a bottle has

    /// Whether the bottle has the runtime, from Magic Kettle or from the player's own installer.
    public static func isInstalled(_ redist: RuntimeManifest.Redist, in bottle: URL) -> Bool {
        let folder = bottle.appending(path: "drive_c", directoryHint: .isDirectory)
            .appending(path: redist.check, directoryHint: .isDirectory)
        switch redist.kindValue {
        case .dotnet?:
            return FileManager.default.fileExists(atPath: folder.path)
        case .vcrun?:
            guard let dll = redist.provides.first else { return false }
            return candidates(of: dll, in: folder, architecture: redist.architecture).contains { !isWineStandIn($0) }
        case nil:
            return false
        }
    }

    /// `dll` in `folder`, and in the folders inside it: Visual C++ 2005 and 2008 live in `winsxs/<assembly>/`,
    /// where the 32-bit assemblies' folders start with `x86_` and the 64-bit ones' with `amd64_`.
    private static func candidates(of dll: String, in folder: URL, architecture: String) -> [URL] {
        let fileManager = FileManager.default
        let direct = folder.appending(path: dll)
        var found = fileManager.fileExists(atPath: direct.path) ? [direct] : []
        let prefix = architecture == "x86" ? "x86_" : "amd64_"
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) {
            let inside = folder.appending(path: name, directoryHint: .isDirectory).appending(path: dll)
            if fileManager.fileExists(atPath: inside.path) { found.append(inside) }
        }
        return found
    }

    /// Wine's own copy of a DLL (or the placeholder `wineboot` puts in `system32` for it), which says so where
    /// a DOS program would print its "can't be run in DOS mode" message.
    static func isWineStandIn(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 0x80) else { return false }
        return ["Wine builtin DLL", "Wine placeholder DLL"].contains { head.range(of: Data($0.utf8)) != nil }
    }

    /// Moves Wine's copies of the runtime's DLLs aside before its installer runs: an installer keeps what it
    /// takes for the same version. Wine's Visual C++ 2008 is a side-by-side assembly named exactly like
    /// Microsoft's 9.0.30729.6161, so its installer said it was done and the game still got Wine's copy; that
    /// one steps aside as a whole, with its manifest.
    static func setAsideStandIns(of redist: RuntimeManifest.Redist, in bottle: URL) -> [URL] {
        guard redist.kindValue == .vcrun else { return [] }
        let folder = bottle.appending(path: "drive_c", directoryHint: .isDirectory)
            .appending(path: redist.check, directoryHint: .isDirectory)
        let standIns = redist.provides.flatMap { candidates(of: $0, in: folder, architecture: redist.architecture) }
            .filter(isWineStandIn)
        var items: [URL] = []
        for file in standIns {
            let assembly = file.deletingLastPathComponent()
            guard folder.lastPathComponent == "winsxs", assembly.standardizedFileURL != folder.standardizedFileURL
            else {
                items.append(file)
                continue
            }
            let manifest = folder.appending(path: "manifests/\(assembly.lastPathComponent).manifest")
            items += [assembly, manifest].filter { !items.contains($0) }
        }
        return items.filter { (try? FileManager.default.moveItem(at: $0, to: aside($0))) != nil }
    }

    /// Puts Wine's copies back where the installer left nothing: without one there, Wine finds no DLL at all.
    static func restore(_ standIns: [URL]) {
        for file in standIns {
            if FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.removeItem(at: aside(file))
            } else {
                try? FileManager.default.moveItem(at: aside(file), to: file)
            }
        }
    }

    private static func aside(_ file: URL) -> URL {
        file.deletingLastPathComponent().appending(path: file.lastPathComponent + ".magickettle-wine")
    }

    public static func marker(in bottle: URL) -> Marker {
        guard let data = try? Data(contentsOf: bottle.appending(path: markerName)),
              let marker = try? JSONDecoder().decode(Marker.self, from: data) else { return Marker() }
        return marker
    }

    /// This exact download already failed in the bottle.
    public static func failedBefore(_ redist: RuntimeManifest.Redist, in bottle: URL) -> Bool {
        marker(in: bottle).failed.contains { $0.id == redist.id && $0.sha256 == redist.sha256 }
    }

    static func record(_ redist: RuntimeManifest.Redist, installed: Bool, in bottle: URL) throws {
        var marker = marker(in: bottle)
        let entry = Marker.Entry(id: redist.id, version: redist.version, sha256: redist.sha256)
        marker.installed.removeAll { $0.id == redist.id }
        marker.failed.removeAll { $0.id == redist.id }
        if installed { marker.installed.append(entry) } else { marker.failed.append(entry) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(to: bottle.appending(path: markerName), options: .atomic)
    }

    // MARK: - Installing

    /// What an install ended with.
    public struct Result: Sendable, Equatable {
        public var installed: Bool
        public var status: Int32
        /// The installer's own output, for the game's log when it failed.
        public var output: String
    }

    /// Downloads the installer and runs it in `bottle`, which must be idle; Wine is down again afterwards.
    /// - Parameter windows: the game's Windows version, put back afterwards. Microsoft's installers run on
    ///   Windows 10: .NET 5 and later refuse anything older, and an XP game may still be built with Visual C++ 2015.
    public func install(_ redist: RuntimeManifest.Redist, into bottle: URL, runtimeFolder: URL,
                        windows: WindowsVersion,
                        progress: @escaping @Sendable (Phase) -> Void = { _ in }) async throws -> Result {
        let download = try await Downloader().fetch(redist, into: paths.downloads) {
            progress(.downloading(received: $0, total: redist.size))
        }
        progress(.installing)

        let wine = Wine(runtimeFolder: runtimeFolder)
        // Inno Setup needed the Mac driver for RPG Maker's packages (`RTPInstaller`); the same for these.
        let environment = WineEnvironment.make(host: host, bottle: bottle.path,
                                               fastSync: WineEnvironment.fastSync(for: nil, wine: wine))
        // Wine must be down to change the Windows version, and a warmed bottle's server may still be up.
        _ = try? await ProcessRunner.run(wine.wineserver.path, ["-k"], environment: environment, timeout: 20)
        let older = windows == .windowsXP || windows == .windows7
        if older { try BottleManager.setWindowsVersion(.windows10, bottle: bottle) }

        // Wine starts a program by its extension, and the download is named by its hash.
        let temp = bottle.appending(path: "drive_c/windows/temp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let setup = temp.appending(path: "magickettle-\(redist.id).exe")
        try? FileManager.default.removeItem(at: setup)
        try FileManager.default.copyItem(at: download, to: setup)
        defer { try? FileManager.default.removeItem(at: setup) }

        let standIns = Self.setAsideStandIns(of: redist, in: bottle)
        defer { Self.restore(standIns) }
        let run = try await ProcessRunner.run(wine.wine.path, [setup.path(percentEncoded: false)] + redist.arguments,
                                              environment: environment, timeout: 20 * 60)
        _ = try? await ProcessRunner.run(wine.wineserver.path, ["-k"], environment: environment, timeout: 20)
        if older { try BottleManager.setWindowsVersion(windows, bottle: bottle) }
        try Task.checkCancellation()

        // An installer's code under Wine isn't always Windows', so what it left behind decides.
        let installed = Self.isInstalled(redist, in: bottle)
        if installed, redist.kindValue == .vcrun {
            // Wine prefers its own copy of a DLL it has one of; Microsoft's is the one the game was built with.
            for dll in redist.provides {
                try BottleManager.setRegistryString(bottle: bottle, key: #"Software\Wine\DllOverrides"#,
                                                    name: String(dll.dropLast(".dll".count)),
                                                    value: "native,builtin")
            }
        }
        try Self.record(redist, installed: installed, in: bottle)
        return Result(installed: installed, status: run.status, output: run.output)
    }
}
