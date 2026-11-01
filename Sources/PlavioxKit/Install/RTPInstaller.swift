import Foundation

/// Installs RPG Maker's Run Time Packages (`RuntimeManifest.RTP`) and makes them visible in game bottles.
///
/// A package is installed once, by its publisher's own installer run silently in a throwaway bottle; what it put
/// down is kept in `Plaviox/RTP/<engine>/<name>` with `RTP.json` written last. Each game that needs it gets a link
/// to that folder where Windows would have it, plus the registry value RGSS reads to find it: one copy for every
/// game instead of 40–600 MB in each bottle.
///
/// Plaviox's links are the ones pointing into `Plaviox/RTP`, which tells them from a package the player installed
/// in the bottle themselves; that one is never replaced.
public struct RTPInstaller: Sendable {
    public static let markerName = "RTP.json"

    /// What `RTP.json` records.
    public struct Marker: Codable, Sendable, Equatable {
        public var engine: String
        public var name: String
        public var version: String
        public var sha256: String
    }

    /// Inno Setup's switches for no window, no questions and no restart. Every package so far is an Inno Setup
    /// installer (XP 1.03/1.04, VX 2.02, VX Ace 1.00).
    static let silentArguments = ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-"]

    let paths: AppPaths
    let host: [String: String]

    public init(paths: AppPaths, host: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.host = host
    }

    /// The package's folder, when this exact download is installed.
    public func installed(_ rtp: RuntimeManifest.RTP) -> URL? {
        let folder = paths.rtp(engine: rtp.engine, name: rtp.name)
        guard let data = try? Data(contentsOf: folder.appending(path: Self.markerName)),
              let marker = try? JSONDecoder().decode(Marker.self, from: data),
              marker.sha256 == rtp.sha256 else { return nil }
        return folder
    }

    /// Downloads and installs the package unless it is there already.
    @discardableResult
    public func install(_ rtp: RuntimeManifest.RTP, runtime: RuntimeManifest.Runtime,
                        progress: @escaping @Sendable (RedistInstaller.Phase) -> Void = { _ in }) async throws -> URL {
        if let folder = installed(rtp) { return folder }
        let download = try await Downloader().fetch(rtp, into: paths.downloads) {
            progress(.downloading(received: $0, total: rtp.size))
        }
        progress(.installing)

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.rtps, withIntermediateDirectories: true)
        let staging = paths.rtps.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let setup = try await Self.unpack(download, setup: rtp.setup, into: staging)
        let bottle = staging.appending(path: "bottle", directoryHint: .isDirectory)
        let template = try await BottleManager(paths: paths, host: host).ensureTemplate(for: runtime)
        try BottleManager.clone(template, to: bottle)
        guard let runtimeFolder = RuntimeInstaller(paths: paths).installed(runtime) else {
            throw BottleError.runtimeMissing(runtime.id)
        }
        let wine = Wine(runtimeFolder: runtimeFolder)
        // With the Mac driver, unlike the template's wineboot: Inno Setup quits with code 1 and installs nothing
        // when Wine has no display, even with `/VERYSILENT`, which shows no window.
        let environment = WineEnvironment.make(host: host, bottle: bottle.path,
                                               fastSync: WineEnvironment.fastSync(for: nil, wine: wine))
        let result = try await ProcessRunner.run(wine.wine.path, [setup.path(percentEncoded: false)]
                                                     + Self.silentArguments,
                                                 environment: environment, timeout: 15 * 60)
        // Nothing of the throwaway bottle is needed from Wine's memory; whatever still runs there just ends.
        _ = try? await ProcessRunner.run(wine.wineserver.path, ["-k"], environment: environment, timeout: 20)

        let kept = staging.appending(path: "rtp", directoryHint: .isDirectory)
        guard try Self.collect(rtp, from: bottle, into: kept) else {
            throw RTPError.installFailed(rtp.name, status: result.status)
        }
        let marker = Marker(engine: rtp.engine, name: rtp.name, version: rtp.version, sha256: rtp.sha256)
        try JSONEncoder().encode(marker).write(to: kept.appending(path: Self.markerName))

        let destination = paths.rtp(engine: rtp.engine, name: rtp.name)
        if installed(rtp) != nil { return destination }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // An older version of the package goes; bottles link to the folder by name, so they get the new one.
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: kept, to: destination)
        return destination
    }

    /// The installer, ready to run: the download itself, or the file `setup` names inside the downloaded zip.
    /// The zips' Japanese readme names are Shift-JIS, which `unzip` refuses and `ditto` takes.
    static func unpack(_ download: URL, setup: String, into staging: URL) async throws -> URL {
        if setup.isEmpty {
            let exe = staging.appending(path: "setup.exe")
            try FileManager.default.copyItem(at: download, to: exe)
            return exe
        }
        let archive = staging.appending(path: "archive", directoryHint: .isDirectory)
        try await ProcessRunner.check("/usr/bin/ditto", ["-x", "-k", download.path, archive.path])
        let exe = archive.appending(path: setup)
        guard FileManager.default.fileExists(atPath: exe.path) else { throw RTPError.setupMissing(setup) }
        return exe
    }

    /// Moves what the installer put down into `kept`: the package folder, and XP's engine DLLs, which its
    /// installer puts into Windows' own folder rather than the package's. The uninstaller stays behind.
    /// Returns false when the package folder isn't there: the installer failed.
    static func collect(_ rtp: RuntimeManifest.RTP, from bottle: URL, into kept: URL) throws -> Bool {
        let fileManager = FileManager.default
        let folder = commonFiles(in: bottle).appending(path: "Enterbrain/\(rtp.engine)/\(rtp.name)",
                                                       directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: folder.path) else { return false }
        try fileManager.moveItem(at: folder, to: kept)
        for name in try fileManager.contentsOfDirectory(atPath: kept.path) where name.hasPrefix("unins") {
            try fileManager.removeItem(at: kept.appending(path: name))
        }
        for system in ["syswow64", "system32"] {
            let windows = bottle.appending(path: "drive_c/windows/\(system)", directoryHint: .isDirectory)
            for name in (try? fileManager.contentsOfDirectory(atPath: windows.path)) ?? [] where isEngine(name)
                && !fileManager.fileExists(atPath: kept.appending(path: name).path) {
                try fileManager.moveItem(at: windows.appending(path: name), to: kept.appending(path: name))
            }
        }
        return true
    }

    /// `RGSS103J.dll`, `RGSS202E.dll`.
    static func isEngine(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper.hasPrefix("RGSS") && upper.hasSuffix(".DLL")
    }

    // MARK: - In a game's bottle

    /// Makes the package visible to the game in `bottle`: a link where its installer would have put it, links to
    /// its engine DLLs in Windows' folder for 32-bit programs (XP games load theirs from there), and with
    /// `registry` the value RGSS reads to find the package. The registry only while the bottle's Wine is down
    /// (`WineRegistry`).
    public static func link(_ folder: URL, engine: String, name: String, into bottle: URL, registry: Bool) throws {
        let fileManager = FileManager.default
        let parent = commonFiles(in: bottle).appending(path: "Enterbrain/\(engine)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try place(link: parent.appending(path: name), to: folder)

        let system = systemFolderFor32Bit(in: bottle)
        for dll in try fileManager.contentsOfDirectory(atPath: folder.path) where isEngine(dll) {
            try place(link: system.appending(path: dll), to: folder.appending(path: dll))
        }

        guard registry else { return }
        let key = registryKey(engine: engine, in: bottle)
        let value = windowsPath(engine: engine, name: name, in: bottle)
        let text = try String(contentsOf: bottle.appending(path: "system.reg"), encoding: .utf8)
        // A package the player installed somewhere else keeps its own path.
        let current = WineRegistry.string(in: text, key: key, name: name)
        if let current, current.caseInsensitiveCompare(value) != .orderedSame,
           let installed = WindowsPath.macURL(for: current, bottle: bottle),
           FileManager.default.fileExists(atPath: installed.path) { return }
        try BottleManager.setRegistryString(bottle: bottle, key: key, name: name, value: value, file: "system.reg")
    }

    /// A link at `item` to `target`, unless something that isn't Plaviox's link is already there.
    private static func place(link item: URL, to target: URL) throws {
        let fileManager = FileManager.default
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: item.path) {
            guard destination != target.path, isOurs(destination) else { return }
            try fileManager.removeItem(at: item)
        } else if fileManager.fileExists(atPath: item.path) {
            return
        }
        try fileManager.createSymbolicLink(atPath: item.path, withDestinationPath: target.path)
    }

    /// A link into any `Plaviox/RTP`, so links made under another `PLAVIOX_HOME` still count as Plaviox's.
    private static func isOurs(_ destination: String) -> Bool {
        destination.contains("/RTP/RGSS")
    }

    /// RGSS runs as a 32-bit program: on 64-bit Windows its files and keys are the WOW64 ones.
    private static func is64Bit(_ bottle: URL) -> Bool {
        FileManager.default.fileExists(atPath: bottle.appending(path: "drive_c/windows/syswow64").path)
    }

    private static func commonFiles(in bottle: URL) -> URL {
        bottle.appending(path: is64Bit(bottle) ? "drive_c/Program Files (x86)/Common Files"
                                                : "drive_c/Program Files/Common Files", directoryHint: .isDirectory)
    }

    private static func systemFolderFor32Bit(in bottle: URL) -> URL {
        bottle.appending(path: is64Bit(bottle) ? "drive_c/windows/syswow64" : "drive_c/windows/system32",
                         directoryHint: .isDirectory)
    }

    /// `HKLM\Software\Enterbrain\RGSS2\RTP` as a 32-bit program sees it.
    static func registryKey(engine: String, in bottle: URL) -> String {
        (is64Bit(bottle) ? #"Software\Wow6432Node\Enterbrain\"# : #"Software\Enterbrain\"#) + engine + #"\RTP"#
    }

    static func windowsPath(engine: String, name: String, in bottle: URL) -> String {
        (is64Bit(bottle) ? #"C:\Program Files (x86)\Common Files\Enterbrain\"#
                         : #"C:\Program Files\Common Files\Enterbrain\"#) + engine + "\\" + name
    }
}

public enum RTPError: Error, Equatable, CustomStringConvertible {
    case setupMissing(String)
    case installFailed(String, status: Int32)

    public var description: String {
        switch self {
        case let .setupMissing(path):
            "The RPG Maker files downloaded, but their installer (\(path)) wasn't in them."
        case let .installFailed(name, status):
            "Couldn't install the RPG Maker files this game needs (\(name), code \(status))."
        }
    }
}
