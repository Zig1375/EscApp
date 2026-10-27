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

    /// Written into a bottle so EscApp knows which runtime made it (to move it to a newer one later).
    public struct BottleInfo: Codable, Sendable, Equatable {
        public var runtime: String
        public var createdAt: Date
        /// The runtime the bottle was moved from, when it was.
        public var movedFrom: String?
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
        // Each build gets its own staging folder: two games started at once on a new runtime both build the
        // template, and sharing one folder made their wineboots trample each other's files.
        let staging = paths.templates.appending(path: ".staging-\(runtime.id)-\(UUID().uuidString)",
                                                directoryHint: .isDirectory)
        Self.removeStaleStaging(in: paths.templates)

        let wine = Wine(runtimeFolder: runtimeFolder)
        // Without its own Wine Mono, wineboot opens Wine's "install Wine Mono?" dialog and would fetch an
        // unpinned download. A runtime must carry it; say so instead of showing that dialog.
        guard Self.hasMono(wine) else { throw BottleError.monoMissing(runtime.id) }
        do {
            // Without the Mac driver: our Wine build shows "updating the Wine configuration" over the Mac while
            // wineboot works, and the template needs no display. Games run with the driver as usual.
            let environment = WineEnvironment.make(
                host: host, bottle: staging.path,
                extra: ["WINEDLLOVERRIDES": WineEnvironment.dllOverrides + ";winemac.drv=d"],
                fastSync: WineEnvironment.fastSync(for: nil, wine: wine))
            try await ProcessRunner.check(wine.wine.path, ["wineboot", "--init"], environment: environment)
            // wineboot returns before wineserver has written the registry to disk.
            try await ProcessRunner.check(wine.wineserver.path, ["-w"], environment: environment)

            try SharedProfile.link(userFolder: try Self.userFolder(in: staging), to: paths.profile)
            try WindowsFonts.link(bottle: staging)
            try Self.setWindowsVersion(.default, bottle: staging)
            let marker = try JSONEncoder.iso.encode(BottleInfo(runtime: runtime.id, createdAt: Date()))
            try marker.write(to: staging.appending(path: Self.templateMarker))

            try Self.publish(staging, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: staging)
            if hasTemplate(for: runtime) { return destination }
            throw error
        }
    }

    /// Makes a finished staging folder the template. Whichever build finishes first wins; the others' work is
    /// thrown away. A destination without its marker is an unfinished leftover and is replaced.
    static func publish(_ staging: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let done = { fileManager.fileExists(atPath: destination.appending(path: templateMarker).path) }
        if done() {
            try? fileManager.removeItem(at: staging)
            return
        }
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            if !done() { throw error }
        }
    }

    /// Staging folders left by a build that was killed. A build takes about 35 s, so an hour-old one is dead.
    static func removeStaleStaging(in templates: URL) {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey]
        let folders = (try? fileManager.contentsOfDirectory(at: templates, includingPropertiesForKeys: keys)) ?? []
        for folder in folders where folder.lastPathComponent.hasPrefix(".staging-") {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if Date().timeIntervalSince(created) > 3600 { try? fileManager.removeItem(at: folder) }
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
        if let info = bottleInfo(for: game), info.runtime != runtime.id {
            try await move(game, from: info.runtime, to: runtime)
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
        try WindowsFonts.link(bottle: folder)
        return folder
    }

    /// Advanced → "Reset Windows": the game's next launch makes a clean bottle from the template. Saves live in
    /// the shared profile and the game in its own folder, so neither goes. The bottle's Wine must be down.
    public func reset(_ game: GameID) throws {
        let folder = bottleFolder(for: game)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// Moves a bottle made by another runtime onto this one (see `BottleMigration`). The new bottle is built
    /// next to the old one and swapped in at once, so a crash halfway leaves the old bottle as it was.
    private func move(_ game: GameID, from old: String, to runtime: RuntimeManifest.Runtime) async throws {
        let fileManager = FileManager.default
        let folder = bottleFolder(for: game)
        let template = try await ensureTemplate(for: runtime)
        let prefix = ".moving-\(game)-"
        for name in (try? fileManager.contentsOfDirectory(atPath: paths.bottles.path)) ?? []
        where name.hasPrefix(prefix) {
            try? fileManager.removeItem(at: paths.bottles.appending(path: name))
        }
        let staging = paths.bottles.appending(path: prefix + UUID().uuidString, directoryHint: .isDirectory)
        do {
            try Self.clone(template, to: staging)
            try? fileManager.removeItem(at: staging.appending(path: Self.templateMarker))
            let oldTemplate = paths.template(forRuntime: old)
            let hasOldTemplate = fileManager.fileExists(atPath: oldTemplate.appending(path: Self.templateMarker).path)
            try BottleMigration.carry(from: folder, oldTemplate: hasOldTemplate ? oldTemplate : nil, into: staging)
            let info = BottleInfo(runtime: runtime.id, createdAt: Date(), movedFrom: old)
            try JSONEncoder.iso.encode(info).write(to: staging.appending(path: Self.bottleMarker))
            guard renamex_np(staging.path, folder.path, UInt32(RENAME_SWAP)) == 0 else {
                throw BottleError.moveFailed(String(cString: strerror(errno)))
            }
        } catch let error as BottleError {
            try? fileManager.removeItem(at: staging)
            throw error
        } catch {
            try? fileManager.removeItem(at: staging)
            throw BottleError.moveFailed(error.localizedDescription)
        }
        // After the swap, `staging` holds the old bottle.
        try? fileManager.removeItem(at: staging)
        removeUnusedTemplates(keeping: runtime.id)
    }

    /// Templates of earlier runtimes stay while a bottle still needs them for its move (~330 MB each), and go
    /// once the last one has moved.
    public func removeUnusedTemplates(keeping current: String) {
        let fileManager = FileManager.default
        let bottles = (try? fileManager.contentsOfDirectory(atPath: paths.bottles.path)) ?? []
        let used = Set(bottles.filter { !$0.hasPrefix(".") }.compactMap { name -> String? in
            let marker = paths.bottles.appending(path: name).appending(path: Self.bottleMarker)
            guard let data = try? Data(contentsOf: marker) else { return nil }
            return (try? JSONDecoder.iso.decode(BottleInfo.self, from: data))?.runtime
        })
        for name in (try? fileManager.contentsOfDirectory(atPath: paths.templates.path)) ?? []
        where !name.hasPrefix(".") && name != current && !used.contains(name) {
            try? fileManager.removeItem(at: paths.templates.appending(path: name))
        }
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

    static func hasMono(_ wine: Wine) -> Bool {
        let mono = wine.root.appending(path: "share/wine/mono", directoryHint: .isDirectory)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: mono.path)) ?? []
        return entries.contains { $0.hasPrefix("wine-mono-") }
    }

    /// The Windows user folder wineboot made (named after the Mac user).
    static func userFolder(in bottle: URL) throws -> URL {
        let users = bottle.appending(path: "drive_c/users", directoryHint: .isDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: users.path)
            .filter { $0 != "Public" && !$0.hasPrefix(".") }
        guard names.count == 1, let name = names.first else { throw BottleError.unexpectedUsers(names) }
        return users.appending(path: name, directoryHint: .isDirectory)
    }

    /// APFS clone; a plain copy when the folders are on a volume without clones (e.g. a ESCAPP_HOME on exFAT).
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

    /// Whether this Wine has osync, read from the runtime it belongs to (`RUNTIME.json` next to every tree,
    /// `wine` and the backends' clones alike). False for a tree outside a runtime folder.
    public var supportsFastSync: Bool {
        runtime?.wineHas(WineEnvironment.fastSyncFeature) ?? false
    }

    /// The runtime this tree belongs to, from its `RUNTIME.json`; nil for a tree outside a runtime folder.
    public var runtime: RuntimeManifest.Runtime? {
        let marker = root.deletingLastPathComponent().appending(path: RuntimeInstaller.markerName)
        guard let data = try? Data(contentsOf: marker) else { return nil }
        return try? JSONDecoder().decode(RuntimeManifest.Runtime.self, from: data)
    }
}

public enum BottleError: Error, Equatable, CustomStringConvertible {
    case runtimeMissing(String)
    case unexpectedUsers([String])
    case cloneFailed(String)
    case monoMissing(String)
    case moveFailed(String)

    public var description: String {
        switch self {
        case let .runtimeMissing(id): "The Windows components (\(id)) aren't installed."
        case let .unexpectedUsers(names): "Windows was set up with unexpected user folders: \(names)."
        case let .cloneFailed(reason): "Couldn't prepare a copy of Windows for this game: \(reason)."
        case let .monoMissing(id): "The Windows components (\(id)) are incomplete: Wine Mono is missing."
        case let .moveFailed(reason): "Couldn't move this game to the updated Windows components: \(reason)."
        }
    }
}
