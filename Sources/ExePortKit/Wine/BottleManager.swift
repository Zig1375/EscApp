import Darwin
import Foundation

/// Creates bottles without the user ever seeing one.
///
/// Each runtime gets one template, made once with `wineboot` (about 20 seconds). A game's bottle is an APFS
/// clone of that template: it takes ~20 ms and almost no space, because clones share blocks until one side
/// writes. Measured in the design phase: 294 MB template, ~0.6 MB per fresh clone.
public struct BottleManager: Sendable {
    public static let templateMarker = "TEMPLATE.json"
    public static let bottleMarker = "BOTTLE.json"

    /// Written into a bottle so ExePort knows which runtime made it (to move it to a newer one later).
    public struct BottleInfo: Codable, Sendable, Equatable {
        public var runtime: String
        public var createdAt: Date
    }

    let paths: AppPaths
    let host: [String: String]

    public init(paths: AppPaths, host: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.host = host
    }

    public func templateFolder(for runtime: RuntimeManifest.Runtime) -> URL {
        paths.template(forRuntime: runtime.id)
    }

    public func hasTemplate(for runtime: RuntimeManifest.Runtime) -> Bool {
        FileManager.default.fileExists(atPath: templateFolder(for: runtime).appending(path: Self.templateMarker).path)
    }

    /// Makes the runtime's template unless it exists. Like runtimes, it is built in a staging folder and only
    /// counts once its marker is written, so an interrupted `wineboot` never becomes every game's Windows.
    @discardableResult
    public func ensureTemplate(for runtime: RuntimeManifest.Runtime) async throws -> URL {
        let destination = templateFolder(for: runtime)
        if hasTemplate(for: runtime) { return destination }
        guard let runtimeFolder = RuntimeInstaller(paths: paths).installed(runtime) else {
            throw BottleError.runtimeMissing(runtime.id)
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.templates, withIntermediateDirectories: true)
        let staging = paths.templates.appending(path: ".staging-\(runtime.id)", directoryHint: .isDirectory)
        try? fileManager.removeItem(at: staging)

        do {
            let wine = Wine(runtimeFolder: runtimeFolder)
            let environment = WineEnvironment.make(host: host, bottle: staging.path)
            try await ProcessRunner.check(wine.wine.path, ["wineboot", "--init"], environment: environment)
            // wineboot returns before wineserver has written the registry to disk.
            try await ProcessRunner.check(wine.wineserver.path, ["-w"], environment: environment)

            try SharedProfile.link(userFolder: try Self.userFolder(in: staging), to: paths.profile)
            try Self.setWindowsVersion(.default, bottle: staging)
            let marker = try JSONEncoder.iso.encode(BottleInfo(runtime: runtime.id, createdAt: Date()))
            try marker.write(to: staging.appending(path: Self.templateMarker))

            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staging, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    public func bottleFolder(for game: GameID) -> URL { paths.bottle(forGame: game) }

    public func bottleInfo(for game: GameID) -> BottleInfo? {
        let marker = bottleFolder(for: game).appending(path: Self.bottleMarker)
        guard let data = try? Data(contentsOf: marker) else { return nil }
        return try? JSONDecoder.iso.decode(BottleInfo.self, from: data)
    }

    /// The game's bottle, cloned from the template the first time.
    @discardableResult
    public func ensureBottle(for game: GameID, runtime: RuntimeManifest.Runtime,
                             windows: WindowsVersion = .default) async throws -> URL {
        let folder = bottleFolder(for: game)
        // A bottle from another runtime is made again from this runtime's template: Wine doesn't support running
        // a prefix with an older Wine than the one that last updated it. Saves live in the shared profile, so
        // nothing of the player's is lost. Until installers exist (M5) nothing else lives in a bottle; before
        // then this must become a migration that carries over what the game installed.
        if let info = bottleInfo(for: game), info.runtime != runtime.id {
            try FileManager.default.removeItem(at: folder)
        }
        if bottleInfo(for: game) == nil {
            let template = try await ensureTemplate(for: runtime)
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: paths.bottles, withIntermediateDirectories: true)
            // A folder without a marker is a clone that didn't finish.
            try? fileManager.removeItem(at: folder)
            try Self.clone(template, to: folder)
            try? fileManager.removeItem(at: folder.appending(path: Self.templateMarker))
            let marker = try JSONEncoder.iso.encode(BottleInfo(runtime: runtime.id, createdAt: Date()))
            try marker.write(to: folder.appending(path: Self.bottleMarker))
        }
        try Self.setWindowsVersion(windows, bottle: folder)
        return folder
    }

    /// Writes the Windows version into the bottle's registry, touching the file only if it changes.
    /// Call it only while the bottle's wineserver isn't running (see `WineRegistry`).
    public static func setWindowsVersion(_ version: WindowsVersion, bottle: URL) throws {
        let userReg = bottle.appending(path: "user.reg")
        let text = try String(contentsOf: userReg, encoding: .utf8)
        guard WindowsVersion.read(fromUserReg: text) != version else { return }
        try version.write(toUserReg: text).write(to: userReg, atomically: true, encoding: .utf8)
    }

    public static func windowsVersion(of bottle: URL) -> WindowsVersion {
        let text = try? String(contentsOf: bottle.appending(path: "user.reg"), encoding: .utf8)
        return text.flatMap(WindowsVersion.read(fromUserReg:)) ?? .default
    }

    /// The Windows user folder wineboot made (named after the Mac user).
    static func userFolder(in bottle: URL) throws -> URL {
        let users = bottle.appending(path: "drive_c/users", directoryHint: .isDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: users.path)
            .filter { $0 != "Public" && !$0.hasPrefix(".") }
        guard names.count == 1, let name = names.first else { throw BottleError.unexpectedUsers(names) }
        return users.appending(path: name, directoryHint: .isDirectory)
    }

    /// APFS clone; a plain copy when the folders are on a volume without clones (e.g. a EXEPORT_HOME on exFAT).
    static func clone(_ source: URL, to destination: URL) throws {
        if Darwin.clonefile(source.path, destination.path, 0) == 0 { return }
        let error = errno
        guard error == ENOTSUP || error == EXDEV else {
            throw BottleError.cloneFailed(String(cString: strerror(error)))
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

/// The executables inside an installed runtime.
public struct Wine: Sendable {
    public let root: URL

    public init(runtimeFolder: URL) {
        root = runtimeFolder.appending(path: "wine", directoryHint: .isDirectory)
    }

    public init(root: URL) {
        self.root = root
    }

    public var wine: URL { root.appending(path: "bin/wine") }
    public var wineserver: URL { root.appending(path: "bin/wineserver") }
}

public enum BottleError: Error, Equatable, CustomStringConvertible {
    case runtimeMissing(String)
    case unexpectedUsers([String])
    case cloneFailed(String)

    public var description: String {
        switch self {
        case let .runtimeMissing(id): "The Windows components (\(id)) aren't installed."
        case let .unexpectedUsers(names): "Windows was set up with unexpected user folders: \(names)."
        case let .cloneFailed(reason): "Couldn't prepare a copy of Windows for this game: \(reason)."
        }
    }
}
