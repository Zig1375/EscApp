import CryptoKit
import Foundation

/// Works out which game an executable belongs to, so it always gets the same bottle and settings.
///
/// A hash of the exe alone isn't enough: Unity games all ship the same renamed player, old GOG games all start
/// through `DOSBox.exe`, and a patch changes the hash. So the main sign is a small `.escapp` file in the game's
/// folder (like `.git` in a repository). It survives moves, copies to other disks, archives and patches.
/// Where `.escapp` can't be written (disc image, read-only folder), the last known path and then a fingerprint
/// of the exe and its folder find the game again.
public struct GameIdentifier: Sendable {
    public static let markerName = ".escapp"
    /// How many folders above the exe's own folder are searched for `.escapp`, so `Game/bin/x64/game.exe` and
    /// `Game/launcher.exe` find the same `Game/.escapp`.
    static let levelsUp = 3

    public enum Method: String, Sendable, Equatable {
        case marker, copiedFolder, lastPath, fingerprint, new
    }

    public struct Result: Sendable, Equatable {
        public var record: GameRecord
        public var method: Method
        public var isNew: Bool { method == .new || method == .copiedFolder }
    }

    struct Marker: Codable {
        var format = 1
        var id: GameID
    }

    let paths: AppPaths
    /// Shared folders where `.escapp` is never created or read: one there would make every game in it one game.
    let stopFolders: Set<String>

    public init(paths: AppPaths, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.paths = paths
        stopFolders = Set(([home, paths.games] + ["Games", "Downloads", "Desktop", "Documents"].map {
            home.appending(path: $0, directoryHint: .isDirectory)
        }).map(Self.key) + ["/"])
    }

    public func identify(executable: URL, now: Date = Date()) throws -> Result {
        let exe = executable.resolvingSymlinksInPath().standardizedFileURL
        let exeFolder = exe.deletingLastPathComponent()
        var library = try GameLibrary.load(from: paths.library)
        defer { try? library.save(to: paths.library) }

        if let (folder, id) = findMarker(from: exeFolder) {
            if var record = library[id] {
                let recordedFolder = URL(filePath: record.folder, directoryHint: .isDirectory)
                if Self.key(recordedFolder) != Self.key(folder), readMarker(in: recordedFolder) == id {
                    // The same .escapp in two existing folders: the folder was copied (to try mods, say).
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
            // A .escapp EscApp doesn't know: the game came from another Mac, or Games.json was lost. Keep its id.
            var record = newRecord(exe: exe, folder: folder, now: now)
            record.id = id
            library[id] = record
            return Result(record: record, method: .marker)
        }

        let root = gameRoot(for: exeFolder)
        let canMark = !isStopFolder(root)
        if var record = library.games.first(where: { $0.executable == exe.path(percentEncoded: false) }) {
            if canMark, !record.hasMarker, (try? writeMarker(record.id, in: root)) != nil {
                record.hasMarker = true
                record.folder = root.path(percentEncoded: false)
            }
            library[record.id] = record
            return Result(record: record, method: .lastPath)
        }

        let fingerprint = try Self.fingerprint(of: exe)
        if var record = library.games.first(where: { $0.fingerprint == fingerprint }) {
            record.executable = exe.path(percentEncoded: false)
            record.folder = root.path(percentEncoded: false)
            library[record.id] = record
            return Result(record: record, method: .fingerprint)
        }

        var record = newRecord(exe: exe, folder: root, now: now)
        if canMark, (try? writeMarker(record.id, in: root)) != nil {
            record.hasMarker = true
        } else {
            record.hasMarker = false
            record.fingerprint = fingerprint
        }
        library[record.id] = record
        return Result(record: record, method: .new)
    }

    /// Folders that hold a game's executables rather than the game itself.
    static let binaryFolderNames: Set<String> = [
        "bin", "bin32", "bin64", "binaries", "x86", "x64", "win32", "win64", "system", "exe", "executable",
    ]

    /// Where a new `.escapp` goes and what names the game: the exe's folder, unless that is one of the binary
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

    /// The nearest `.escapp` at or above `start`, never looking into or past a shared folder.
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
        let file = folder.appending(path: Self.markerName)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONDecoder().decode(Marker.self, from: data))?.id
    }

    func writeMarker(_ id: GameID, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(Marker(id: id)).write(to: folder.appending(path: Self.markerName), options: .atomic)
    }

    private func newRecord(exe: URL, folder: URL, now: Date) -> GameRecord {
        let name = Self.name(exe: exe, root: folder, rootIsShared: isStopFolder(folder))
        // Whole seconds, the precision Games.json keeps, so a record reads back equal to what was saved.
        let added = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        return GameRecord(id: .make(), name: name, executable: exe.path(percentEncoded: false),
                          folder: folder.path(percentEncoded: false), hasMarker: false, addedAt: added)
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

    /// The exe's hash plus the names and sizes of the files next to it. The folder part tells apart two games
    /// that share an identical exe (Unity player, DOSBox).
    static func fingerprint(of exe: URL) throws -> String {
        let folder = exe.deletingLastPathComponent()
        let listing = try FileManager.default
            .contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent != markerName }
            .map { "\($0.lastPathComponent)\t\((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)" }
            .sorted()
            .joined(separator: "\n")
        let combined = try Downloader.sha256(of: exe) + "\n" + listing
        return Downloader.hex(SHA256.hash(data: Data(combined.utf8)))
    }

    /// Comparable form of a folder path: resolved, no trailing slash.
    static func key(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
