import Foundation

/// Installs a game from its installer, into the bottle that becomes the game's own: many old games read back
/// what their installer wrote into the registry, so the installer and the game have to share one Windows.
///
/// The game's files go into an ordinary Mac folder (`~/Games/<name>` by default), which the bottle sees as drive
/// `G:`: they stay when the bottle is reset or moved. The installer gets that folder on its command line when it
/// takes one (see `InstallerKind`); afterwards `InstalledPrograms` finds what it put down, wherever it did.
public struct GameInstaller: Sendable {
    public struct Plan: Sendable, Equatable {
        public var installer: URL
        public var kind: InstallerKind
        public var name: String
        /// The game's folder on the Mac. Its parent becomes drive `G:`.
        public var folder: URL
        /// The CD, when installing from one: it is in drive `D:` while the installer runs.
        public var disc: MountedDisc?
        public var windowsVersion: WindowsVersion

        public init(installer: URL, kind: InstallerKind, name: String, folder: URL, disc: MountedDisc? = nil,
                    windowsVersion: WindowsVersion = .default) {
            self.installer = installer
            self.kind = kind
            self.name = name
            self.folder = folder
            self.disc = disc
            self.windowsVersion = windowsVersion
        }
    }

    public enum Step: Sendable, Equatable {
        /// Making the game's Windows; `firstTime` when the runtime's template is built first (~30 s, once).
        case windows(firstTime: Bool)
        /// The installer's own window is up; EscApp waits until it and everything it started have finished.
        case installing
        case findingGame
    }

    public struct Installed: Sendable, Equatable {
        public var id: GameID
        public var plan: Plan
        public var found: InstalledPrograms.Found
        public var log: URL
    }

    public static let gamesDrive: Character = "g"

    let paths: AppPaths
    let host: [String: String]

    public init(paths: AppPaths, host: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.host = host
    }

    /// The name to suggest: the installer's product name without "Setup", else the disc image's or folder's name.
    public static func suggestedName(installer: URL, disc: URL? = nil) -> String {
        let info = try? ExecutableInfo.read(installer)
        let generic = ["setup", "installer", "install", "installation", "launcher", "autorun"]
        for candidate in [info?.versionStrings["ProductName"], info?.productName].compactMap({ $0 }) {
            var name = candidate
            for word in [" Setup", " Installer", " Installation", " Install"]
            where name.lowercased().hasSuffix(word.lowercased()) {
                name = String(name.dropLast(word.count))
            }
            name = name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !generic.contains(name.lowercased()) { return name }
        }
        if let disc { return disc.deletingPathExtension().lastPathComponent }
        // A package is usually named after its game (`Fallout2.msi`); a setup.exe after nothing.
        let file = installer.deletingPathExtension().lastPathComponent
        if !generic.contains(file.lowercased()), info == nil || !file.lowercased().contains("setup") { return file }
        let folder = installer.deletingLastPathComponent().lastPathComponent
        return folder.isEmpty || folder == "/" ? file : folder
    }

    /// `~/Games/<name>`, with characters macOS or Windows can't have in a folder name replaced.
    public func defaultFolder(for name: String) -> URL {
        // Single spaces only: NSIS gets the folder split at its spaces (see `InstallerKind`).
        let safe = String(name.map { #"/\:*?"<>|"#.contains($0) ? "-" : $0 })
        let cleaned = safe.split(separator: " ").joined(separator: " ")
        let trimmed = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        let folder = cleaned.trimmingCharacters(in: trimmed)
        return paths.games.appending(path: folder.isEmpty ? "Game" : folder, directoryHint: .isDirectory)
    }

    /// Runs the installer to the end and finds what it installed. Nothing is in the library yet: `finish` adds the
    /// game once the player picked its program, `cancel` takes the bottle away again.
    public func install(_ plan: Plan, runtime: RuntimeManifest.Runtime,
                        progress: @Sendable (Step) -> Void = { _ in }) async throws -> Installed {
        guard let runtimeFolder = RuntimeInstaller(paths: paths).installed(runtime) else {
            throw BottleError.runtimeMissing(runtime.id)
        }
        let id = GameID.make()
        let bottles = BottleManager(paths: paths, host: host)
        progress(.windows(firstTime: !bottles.hasTemplate(for: runtime)))
        let bottle = try await bottles.ensureBottle(for: id, runtime: runtime, windows: plan.windowsVersion)
        do {
            let target = Target(id: id, bottle: bottle, wine: Wine(runtimeFolder: runtimeFolder),
                                template: paths.template(forRuntime: runtime.id))
            return try await run(plan, in: target, progress: progress)
        } catch {
            cancel(id)
            throw error
        }
    }

    /// Where an install runs.
    private struct Target {
        var id: GameID
        var bottle: URL
        var wine: Wine
        /// The bottle's template, to tell what the installer added.
        var template: URL
    }

    private func run(_ plan: Plan, in target: Target, progress: @Sendable (Step) -> Void) async throws -> Installed {
        let (id, bottle, wine) = (target.id, target.bottle, target.wine)
        let fileManager = FileManager.default
        let gamesRoot = Self.gamesDriveRoot(for: plan)
        try fileManager.createDirectory(at: plan.folder, withIntermediateDirectories: true)
        try DiscDrive.link(bottle.appending(path: "dosdevices/\(Self.gamesDrive):"),
                           to: gamesRoot.path(percentEncoded: false))
        if let disc = plan.disc { try DiscDrive.insert(disc, into: bottle) }
        try BottleManager.disableCrashDialog(bottle: bottle)

        let folder = WindowsPath.windowsPath(of: plan.folder, under: gamesRoot, drive: Self.gamesDrive)
            ?? #"G:\Game"#
        let environment = WineEnvironment.make(host: host, bottle: bottle.path)
        let log = paths.logs(forGame: id).appending(path: "install-\(Self.timestamp()).log")
        try fileManager.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let started = Date().addingTimeInterval(-2)

        progress(.installing)
        let arguments = command(for: plan, folder: folder, bottle: bottle)
        try await Self.runToEnd(wine, arguments, in: plan.installer.deletingLastPathComponent(),
                                environment: environment, log: log)
        // Installers hand their work to other processes (Inno's setup.tmp, msiexec's server) and exit at once:
        // done means the bottle has gone quiet.
        _ = try? await ProcessRunner.run(wine.wineserver.path, ["-w"], environment: environment)

        progress(.findingGame)
        let targets = shortcutTargets(since: started, bottle: bottle)
        let folders = [plan.folder] + InstalledPrograms.newFolders(in: bottle, template: target.template)
        let found = InstalledPrograms.find(in: folders.filter { fileManager.fileExists(atPath: $0.path) },
                                           shortcutTargets: targets, name: plan.name)
        return Installed(id: id, plan: plan, found: found, log: log)
    }

    /// The folder drive `G:` is. Usually the game folder's parent, so the installer's folder page shows
    /// `G:\<name>`. For a Windows Installer package, the game folder itself: msiexec reads a property's value only
    /// unquoted or quoted inside the argument (`INSTALLDIR="G:\My Game"`), `wine` can pass it neither way when it
    /// has a space, and `INSTALLDIR=G:\` has none.
    static func gamesDriveRoot(for plan: Plan) -> URL {
        plan.kind == .windowsInstaller ? plan.folder : plan.folder.deletingLastPathComponent()
    }

    /// What `wine` runs. A file on the disc is started by its `D:` path, as from a real CD: some installers look
    /// for their data next to themselves on the drive they were started from.
    func command(for plan: Plan, folder: String, bottle: URL) -> [String] {
        let path = plan.disc.flatMap { disc -> String? in
            WindowsPath.windowsPath(of: plan.installer, under: disc.mountPoint,
                                    drive: Character(DiscDrive.letter))
        } ?? plan.installer.path(percentEncoded: false)
        let folderArguments = plan.kind.folderArguments(folder)
        switch plan.kind {
        case .windowsInstaller:
            return ["msiexec", "/i", path] + folderArguments
        case .innoSetup, .nsis, .installShield, .other:
            return [path] + folderArguments
        }
    }

    /// Adds the installed game to the library with the program the player picked.
    /// - Parameter keepDisc: the game checks for its CD, so the disc image goes in drive `D:` on every launch.
    @discardableResult
    public func finish(_ installed: Installed, program: URL, keepDisc: Bool) throws -> GameRecord {
        let plan = installed.plan
        let bottle = paths.bottle(forGame: installed.id)
        let exe = program.standardized
        let folder = Self.contains(plan.folder, exe) ? plan.folder.standardized : exe.deletingLastPathComponent()
        var hasMarker = true
        do {
            try GameIdentifier(paths: paths).writeMarker(installed.id, in: folder)
        } catch {
            hasMarker = false
        }
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        var record = GameRecord(id: installed.id, name: plan.name, executable: exe.path(percentEncoded: false),
                                folder: folder.path(percentEncoded: false), hasMarker: hasMarker,
                                windowsVersion: plan.windowsVersion, addedAt: now)
        if keepDisc, let disc = plan.disc { record.disc = disc.image.path(percentEncoded: false) }
        if !keepDisc { DiscDrive.eject(from: bottle) }
        try GameLibrary.modify(paths.library) { $0[record.id] = record }
        return record
    }

    /// Forgets an install that won't be finished: its bottle goes. The game folder stays, it may hold the
    /// player's files.
    public func cancel(_ id: GameID) {
        try? FileManager.default.removeItem(at: paths.bottle(forGame: id))
    }

    // MARK: - Shortcuts

    /// Targets of the shortcuts the installer made, as Mac paths. A shortcut on the Windows desktop lands on the
    /// Mac's own desktop (Wine links the two), so those are read and removed: EscApp is how the game starts.
    func shortcutTargets(since start: Date, bottle: URL) -> [URL] {
        let fileManager = FileManager.default
        let menus = [
            paths.profile.appending(path: "AppData/Roaming/Microsoft/Windows/Start Menu"),
            bottle.appending(path: "drive_c/ProgramData/Microsoft/Windows/Start Menu"),
        ]
        let desktops = [bottle.appending(path: "drive_c/users/Public/Desktop")]
            + ((try? BottleManager.userFolder(in: bottle)).map { [$0.appending(path: "Desktop")] } ?? [])
        var targets: [URL] = []
        for (folder, remove) in menus.map({ ($0, false) }) + desktops.map({ ($0, true) }) {
            for link in Self.shortcuts(in: folder.resolvingSymlinksInPath(), since: start) {
                guard let target = ShellLink.target(of: link),
                      let url = WindowsPath.macURL(for: target, bottle: bottle) else { continue }
                targets.append(url)
                if remove { try? fileManager.removeItem(at: link) }
            }
        }
        return targets
    }

    static func shortcuts(in folder: URL, since start: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { url in
            guard url.pathExtension.lowercased() == "lnk",
                  let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return max(values.contentModificationDate ?? .distantPast, values.creationDate ?? .distantPast) >= start
        }
    }

    // MARK: - Helpers

    static func contains(_ folder: URL, _ file: URL) -> Bool {
        let base = folder.standardized.path(percentEncoded: false)
        let path = file.standardized.path(percentEncoded: false)
        return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }

    /// Runs Wine with its output in `log` and waits for that process.
    static func runToEnd(_ wine: Wine, _ arguments: [String], in folder: URL, environment: [String: String],
                         log: URL) async throws {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        handle.write(Data("[EscApp] Install \(arguments.joined(separator: " "))\n".utf8))
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
        handle.write(Data("[EscApp] Installer exit \(status)\n".utf8))
    }
}
