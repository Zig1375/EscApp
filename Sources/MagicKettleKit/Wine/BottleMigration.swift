import Darwin
import Foundation

/// Moves a game's bottle to a newer runtime without losing what was installed into it.
///
/// A bottle can't simply run on a newer Wine: Wine updates a prefix in place on first start, and a prefix last
/// updated by one version isn't supported on another. So the game gets a fresh clone of the new runtime's
/// template, and what the game (or its installer) changed is carried into it: files that differ from the old
/// template, and registry values that differ from the old template's registry. Both are measured against the
/// old template because a bottle starts as an exact clone of it, so anything else is Wine's own and the new
/// template already has the new Wine's version of it.
enum BottleMigration {
    /// Files at the top of a bottle that are Wine's or Magic Kettle's bookkeeping, never the game's.
    static let ownFiles = registryFiles.union([
        BottleManager.bottleMarker, BottleManager.templateMarker, ".update-timestamp",
    ])
    static let registryFiles: Set<String> = ["system.reg", "user.reg", "userdef.reg"]

    /// Keys Wine fills in itself on every start: the Mac's displays, GPU and input devices, network cards and
    /// fonts. A bottle that ran once differs from its template in all of them, and the new Wine writes its own.
    static let wineManagedKeys = [
        #"System\ControlSet001\Enum"#,
        #"System\ControlSet001\Control\DeviceClasses"#,
        #"System\ControlSet001\Control\Class"#,
        #"System\ControlSet001\Control\Video"#,
        #"Software\Microsoft\Windows NT\CurrentVersion\NetworkCards"#,
        #"Software\Microsoft\Windows NT\CurrentVersion\Fonts"#,
        #"Software\Microsoft\Windows\CurrentVersion\Fonts"#,
        #"Software\Wine\Fonts"#,
    ]

    struct Summary: Equatable {
        var files = 0
        var registryValues = 0
    }

    /// Carries what the game changed in `old` into `new`, a fresh clone of the new template.
    /// - Parameter oldTemplate: the template `old` was cloned from. When it is gone, only what the new template
    ///   lacks entirely is carried: it can no longer be told which differences are the game's.
    @discardableResult
    static func carry(from old: URL, oldTemplate: URL?, into new: URL) throws -> Summary {
        var summary = Summary()
        try carryFolder("", from: old, base: oldTemplate, into: new, summary: &summary)
        for name in registryFiles.sorted() {
            summary.registryValues += try carryRegistry(name, from: old, base: oldTemplate, into: new)
        }
        return summary
    }

    // MARK: - Files

    private static func carryFolder(_ relative: String, from old: URL, base: URL?, into new: URL,
                                    summary: inout Summary) throws {
        let fileManager = FileManager.default
        let source = old.appending(path: relative, directoryHint: .isDirectory)
        for name in try fileManager.contentsOfDirectory(atPath: source.path) {
            if relative.isEmpty, ownFiles.contains(name) { continue }
            let path = relative.isEmpty ? name : relative + "/" + name
            let item = old.appending(path: path)
            let target = new.appending(path: path)
            let original = base?.appending(path: path)

            switch kind(of: item) {
            case .link:
                let destination = try fileManager.destinationOfSymbolicLink(atPath: item.path)
                guard try isGames(target: target, original: original, unchanged: {
                    (try? fileManager.destinationOfSymbolicLink(atPath: $0.path)) == destination
                }) else { continue }
                try replace(target) {
                    try fileManager.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
                }
                summary.files += 1
            case .folder:
                // A folder the old template had is Wine's: only what changed inside it is the game's. Any other
                // folder (`Program Files/Game`) is the game's entirely and is cloned in one step.
                if original.map({ kind(of: $0) == .folder }) == true || kind(of: target) == .folder {
                    try carryFolder(path, from: old, base: base, into: new, summary: &summary)
                } else {
                    try replace(target) { try BottleManager.clone(item, to: target) }
                    summary.files += count(in: item)
                }
            case .file:
                // Wine's stubs for its own DLLs stay behind: the new Wine has made its own.
                guard try isGames(target: target, original: original, unchanged: { try same(item, $0) }),
                      !isWineStub(item) else { continue }
                try replace(target) { try BottleManager.clone(item, to: target) }
                summary.files += 1
            case nil:
                continue
            }
        }
    }

    /// Whether an item is the game's: it changed since the old template was cloned, or, with that template gone,
    /// the new bottle has nothing in its place.
    private static func isGames(target: URL, original: URL?, unchanged: (URL) throws -> Bool) rethrows -> Bool {
        guard let original else { return kind(of: target) == nil }
        return try !unchanged(original)
    }

    /// Puts something at `target` in place of whatever is there. Its folder is made only now: a folder of the
    /// old template's that nothing is carried into (an old Wine's theme) stays out of the new bottle.
    private static func replace(_ target: URL, with make: () throws -> Void) throws {
        let fileManager = FileManager.default
        if kind(of: target) != nil { try fileManager.removeItem(at: target) }
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try make()
    }

    enum Kind { case file, folder, link }

    static func kind(of url: URL) -> Kind? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .link
        case S_IFDIR: return .folder
        case S_IFREG: return .file
        default: return nil
        }
    }

    /// Unchanged since the template was cloned. A clone keeps the original's size and modification date, so
    /// those settle almost every file without reading it.
    static func same(_ file: URL, _ original: URL) throws -> Bool {
        guard kind(of: original) == .file else { return false }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let one = try file.resourceValues(forKeys: keys)
        let other = try original.resourceValues(forKeys: keys)
        guard one.fileSize == other.fileSize else { return false }
        if one.contentModificationDate == other.contentModificationDate { return true }
        return try sameContents(file, original)
    }

    private static func sameContents(_ file: URL, _ original: URL) throws -> Bool {
        let one = try FileHandle(forReadingFrom: file)
        let other = try FileHandle(forReadingFrom: original)
        defer {
            try? one.close()
            try? other.close()
        }
        while true {
            let chunk = try one.read(upToCount: 1 << 20) ?? Data()
            guard chunk == (try other.read(upToCount: 1 << 20) ?? Data()) else { return false }
            if chunk.isEmpty { return true }
        }
    }

    /// Wine marks the DLLs it writes into a bottle's system folders right after the DOS header: those are
    /// placeholders for its builtin DLLs, and an old Wine's copy has no place in a new Wine's bottle.
    static func isWineStub(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 0x60), header.count >= 0x54,
              header.prefix(2) == Data("MZ".utf8) else { return false }
        let mark = header.subdata(in: 0x40..<header.count)
        return mark.starts(with: Data("Wine builtin DLL".utf8)) || mark.starts(with: Data("Wine placeholder DLL".utf8))
    }

    private static func count(in folder: URL) -> Int {
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        var count = 0
        while walker?.nextObject() != nil { count += 1 }
        return count
    }

    // MARK: - Registry

    /// Returns how many values were carried.
    private static func carryRegistry(_ name: String, from old: URL, base: URL?, into new: URL) throws -> Int {
        let target = new.appending(path: name)
        guard let changed = try? String(contentsOf: old.appending(path: name), encoding: .utf8),
              let fresh = try? String(contentsOf: target, encoding: .utf8) else { return 0 }
        var file = RegistryFile(fresh)
        let changes: [RegistryFile.Key]
        if let base, let original = try? String(contentsOf: base.appending(path: name), encoding: .utf8) {
            changes = RegistryFile.changes(from: RegistryFile(original), to: RegistryFile(changed),
                                           skipping: wineManagedKeys)
        } else {
            changes = RegistryFile.changes(from: file, to: RegistryFile(changed), skipping: wineManagedKeys,
                                           onlyMissing: true)
        }
        guard !changes.isEmpty else { return 0 }
        file.apply(changes)
        try file.text.write(to: target, atomically: true, encoding: .utf8)
        return changes.reduce(0) { $0 + $1.values.count }
    }
}
