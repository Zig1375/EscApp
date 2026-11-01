import Foundation

/// Works out which game an executable belongs to, so it always gets the same bottle and settings.
///
/// A hash of the exe alone isn't enough: Unity games all ship the same renamed player, old GOG games all start
/// through `DOSBox.exe`, and a patch changes the hash. So the main sign is a small `.magickettle` file in the game's
/// folder (like `.git` in a repository). It survives moves, copies to other disks, archives and patches.
/// It is the only sign: an exe without one is a new game. The last known path and a fingerprint of the exe used
/// to find a game too, and could take one game for another.
///
/// A store's games are the exception: they have no `.magickettle` and are found by their folder in `Games.json`
/// (`StoreLibrary.sync`), since the store's own folder is never written to.
public struct GameIdentifier: Sendable {
    public static let markerName = ".magickettle"
    /// How many folders above the exe's own folder are searched for `.magickettle`, so `Game/bin/x64/game.exe` and
    /// `Game/launcher.exe` find the same `Game/.magickettle`.
    static let levelsUp = 3

    public enum Method: String, Sendable, Equatable {
        case marker, copiedFolder, new, store
    }

    public enum IdentifyError: Error, Equatable, CustomStringConvertible {
        /// An exe in a store's bottle that isn't one of the store's games Magic Kettle knows.
        case notAStoreGame(Store, path: String)

        public var description: String {
            switch self {
            case let .notAStoreGame(store, path):
                "\(path) is in \(store.name)'s folder but isn't one of its installed games."
            }
        }
    }

    public struct Result: Sendable, Equatable {
        public var record: GameRecord
        public var method: Method
        public var isNew: Bool { method == .new || method == .copiedFolder }
    }

    struct Marker: Codable {
        var format = 1
        var id: GameID
        /// What the game last worked with (`RecommendedSettings`). Older versions ignore it.
        var recommended: RecommendedSettings?
    }

    let paths: AppPaths
    /// Shared folders where `.magickettle` is never created or read: one there would make every game in it one game.
    let stopFolders: Set<String>

    public init(paths: AppPaths, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.paths = paths
        stopFolders = Set(([home, paths.games] + ["Games", "Downloads", "Desktop", "Documents"].map {
            home.appending(path: $0, directoryHint: .isDirectory)
        }).map(Self.key) + ["/"])
    }

    public func identify(executable: URL, now: Date = Date()) throws -> Result {
        try GameLibrary.modify(paths.library) { try identify(executable, now: now, in: &$0) }
    }

    private func identify(_ executable: URL, now: Date, in library: inout GameLibrary) throws -> Result {
        let exe = executable.resolvingSymlinksInPath().standardizedFileURL
        let exeFolder = exe.deletingLastPathComponent()

        // Running Among Us's exe from Steam's folder made a second record for it, wrote `.magickettle` into Steam's
        // game folder and started the game without Steam, which it can't run without.
        if let record = Self.storeGame(at: Self.key(exe), in: library.games) {
            return Result(record: record, method: .store)
        }
        if let store = storeBottle(containing: exe) {
            throw IdentifyError.notAStoreGame(store, path: exe.path(percentEncoded: false))
        }

        if let (folder, id) = findMarker(from: exeFolder) {
            if var record = library[id] {
                let recordedFolder = URL(filePath: record.folder, directoryHint: .isDirectory)
                if Self.key(recordedFolder) != Self.key(folder), readMarker(in: recordedFolder) == id {
                    // The same .magickettle in two existing folders: the folder was copied (to try mods, say).
                    // The copy becomes its own game with its own bottle.
                    let copy = newRecord(exe: exe, folder: folder, now: now)
                    try writeMarker(copy.id, in: folder)
                    library[copy.id] = copy
                    return Result(record: copy, method: .copiedFolder)
                }
                record.folder = folder.path(percentEncoded: false)
                record.executable = exe.path(percentEncoded: false)
                library[id] = record
                return Result(record: record, method: .marker)
            }
            // A .magickettle Magic Kettle doesn't know: the game came from another Mac, or Games.json was lost. Keep
            // its id.
            var record = newRecord(exe: exe, folder: folder, now: now)
            record.id = id
            library[id] = record
            return Result(record: record, method: .marker)
        }

        let root = gameRoot(for: exeFolder)
        var record = newRecord(exe: exe, folder: root, now: now)
        if !isStopFolder(root), (try? writeMarker(record.id, in: root)) != nil { record.hasMarker = true }
        library[record.id] = record
        return Result(record: record, method: .new)
    }

    /// The store game `exe` (a `key`) belongs to: the one it is the recorded program of, or inside the folder of.
    /// The deepest folder wins, should one store game's folder hold another's. Paths compare ignoring case, as
    /// the Mac's disks and Windows do.
    static func storeGame(at exe: String, in games: [GameRecord]) -> GameRecord? {
        let exe = exe.lowercased()
        let stored = games.filter { $0.store != nil }
        if let record = stored.first(where: { key(URL(filePath: $0.executable)).lowercased() == exe }) {
            return record
        }
        return stored
            .map { (record: $0, folder: key(URL(filePath: $0.folder, directoryHint: .isDirectory)).lowercased()) }
            .filter { exe.hasPrefix($0.folder + "/") }
            .max { $0.folder.count < $1.folder.count }?.record
    }

    /// The store whose bottle `exe` is in, where only the store writes.
    public func storeBottle(containing exe: URL) -> Store? {
        Self.storeBottle(containing: Self.key(exe)) { Self.key(paths.bottle(forGame: $0.bottleID)) }
    }

    static func storeBottle(containing exe: String, bottle: (Store) -> String) -> Store? {
        Store.allCases.first { exe.lowercased().hasPrefix(bottle($0).lowercased() + "/") }
    }

    /// Folders that hold a game's executables rather than the game itself.
    static let binaryFolderNames: Set<String> = [
        "bin", "bin32", "bin64", "binaries", "x86", "x64", "win32", "win64", "system", "exe", "executable",
    ]

    /// Where a new `.magickettle` goes and what names the game: the exe's folder, unless that is one of the binary
    /// folders above (`Game/bin/x64/game.exe` → `Game`). Unreal games keep the exe in
    /// `<Root>/<Project>/Binaries/Win64` next to `<Root>/Engine`, with the launcher in `<Root>`, so their root
    /// is the folder that has `Engine`.
    func gameRoot(for exeFolder: URL) -> URL {
        var folder = exeFolder
        for _ in 0..<Self.levelsUp {
            guard Self.binaryFolderNames.contains(folder.lastPathComponent.lowercased()) else { break }
            let parent = folder.deletingLastPathComponent()
            if isStopFolder(parent) { break }
            folder = parent
        }
        let parent = folder.deletingLastPathComponent()
        if folder != exeFolder, !isStopFolder(parent),
           FileManager.default.fileExists(atPath: parent.appending(path: "Engine").path) {
            return parent
        }
        return folder
    }

    /// The nearest `.magickettle` at or above `start`, never looking into or past a shared folder.
    func findMarker(from start: URL) -> (URL, GameID)? {
        var folder = start
        for _ in 0...Self.levelsUp {
            if isStopFolder(folder) { return nil }
            if let id = readMarker(in: folder) { return (folder, id) }
            let parent = folder.deletingLastPathComponent()
            if Self.key(parent) == Self.key(folder) { return nil }
            folder = parent
        }
        return nil
    }

    func isStopFolder(_ folder: URL) -> Bool {
        if stopFolders.contains(Self.key(folder)) { return true }
        // The top of any disk (/Volumes/USB) is as shared as the home folder.
        return (try? folder.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
    }

    func readMarker(in folder: URL) -> GameID? {
        Self.marker(in: folder)?.id
    }

    /// Names the game in `folder`. Settings already in the file stay: a copied folder keeps what worked for the
    /// original.
    func writeMarker(_ id: GameID, in folder: URL) throws {
        try Self.write(Marker(id: id, recommended: Self.marker(in: folder)?.recommended), in: folder)
    }

    static func marker(in folder: URL) -> Marker? {
        guard let data = try? Data(contentsOf: folder.appending(path: markerName)) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    static func write(_ marker: Marker, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(marker).write(to: folder.appending(path: markerName), options: .atomic)
    }

    private func newRecord(exe: URL, folder: URL, now: Date) -> GameRecord {
        let name = Self.name(exe: exe, root: folder, rootIsShared: isStopFolder(folder))
        // Whole seconds, the precision Games.json keeps, so a record reads back equal to what was saved.
        let added = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        var record = GameRecord(id: .make(), name: name, executable: exe.path(percentEncoded: false),
                                folder: folder.path(percentEncoded: false), hasMarker: false, addedAt: added)
        record.retina = SharedSettings.newGameRetina(paths: paths)
        return record
    }

    /// Product names that say which engine or wrapper made the exe, not which game it is.
    static let genericProductNames: Set<String> = [
        "unity", "unityplayer", "shockwave flash", "adobe flash player", "nw.js", "electron", "dosbox",
        "rpg maker", "game", "launcher", "godot engine", "renpy", "ren'py",
    ]

    /// The best name available without the network: Unity's `app.info`, the exe's ProductName, the game folder.
    static func name(exe: URL, root: URL, rootIsShared: Bool) -> String {
        let base = exe.deletingPathExtension().lastPathComponent
        // Unity games keep "company\nproduct" here; the exe itself is the generic Unity player.
        let appInfo = exe.deletingLastPathComponent().appending(path: "\(base)_Data/app.info")
        if let text = try? String(contentsOf: appInfo, encoding: .utf8) {
            let lines = text.components(separatedBy: .newlines)
            if lines.count > 1, !lines[1].trimmingCharacters(in: .whitespaces).isEmpty {
                return lines[1].trimmingCharacters(in: .whitespaces)
            }
        }
        if let product = (try? ExecutableInfo.read(exe))?.productName,
           !genericProductNames.contains(product.lowercased()) {
            return product
        }
        return rootIsShared ? base : root.lastPathComponent
    }

    /// Comparable form of a folder path: resolved, no trailing slash.
    static func key(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
