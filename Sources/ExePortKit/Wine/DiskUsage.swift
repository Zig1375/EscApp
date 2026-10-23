import Foundation

/// What ExePort itself takes on disk, split the way Settings shows it (Settings.dc.html, "Disk space").
///
/// Finder and `du` count every APFS clone in full, so they overstate this a lot: a game's bottle shares almost all
/// of its blocks with the template, and the backend trees (`wine-dxvk`, `wine-dxmt`) share theirs with `wine`.
/// Here a clone only counts the files that differ from what it was cloned from.
public struct DiskUsage: Sendable, Equatable {
    /// Wine and the graphics components.
    public var runtimes: Int64
    /// The clean Windows every game bottle is cloned from.
    public var templates: Int64
    /// What the games' own bottles add on top of the template.
    public var bottles: Int64
    public var bottleCount: Int

    public var total: Int64 { runtimes + templates + bottles }

    public static func measure(paths: AppPaths) -> DiskUsage {
        let fileManager = FileManager.default
        func folders(in root: URL) -> [URL] {
            ((try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                   options: .skipsHiddenFiles)) ?? [])
        }

        var runtimes: Int64 = 0
        for runtime in folders(in: paths.runtimes) {
            for part in folders(in: runtime) {
                if part.lastPathComponent.hasPrefix("wine-") {
                    // A backend tree: only what it replaced differs from `wine`.
                    runtimes += uniqueSize(of: part, against: runtime.appending(path: "wine"))
                } else {
                    runtimes += allocatedSize(of: part)
                }
            }
        }

        let templates = folders(in: paths.templates)
        let templateSize = templates.reduce(Int64(0)) { $0 + allocatedSize(of: $1) }

        var bottles: Int64 = 0
        let bottleFolders = folders(in: paths.bottles)
        for bottle in bottleFolders {
            let runtime = (try? Data(contentsOf: bottle.appending(path: BottleManager.bottleMarker)))
                .flatMap { try? JSONDecoder.iso.decode(BottleManager.BottleInfo.self, from: $0) }?.runtime
            if let runtime {
                bottles += uniqueSize(of: bottle, against: paths.template(forRuntime: runtime))
            } else {
                bottles += allocatedSize(of: bottle)
            }
        }
        return DiskUsage(runtimes: runtimes, templates: templateSize, bottles: bottles,
                         bottleCount: bottleFolders.count)
    }

    static func allocatedSize(of folder: URL) -> Int64 {
        var total: Int64 = 0
        walk(folder) { _, size, _ in total += size }
        return total
    }

    /// Files in `clone` that aren't the same file (same size and modification date) at the same place in `original`.
    static func uniqueSize(of clone: URL, against original: URL) -> Int64 {
        var total: Int64 = 0
        let originalPath = original.resolvingSymlinksInPath().path(percentEncoded: false)
        walk(clone) { relative, size, modified in
            let counterpart = URL(filePath: originalPath).appending(path: relative)
            let values = try? counterpart.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if values?.contentModificationDate != modified || values?.fileSize.map(Int64.init) == nil {
                total += size
            }
        }
        return total
    }

    /// Calls `visit` for each regular file with its path relative to `folder`, allocated size and modification date.
    private static func walk(_ folder: URL, visit: (String, Int64, Date?) -> Void) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        let base = folder.resolvingSymlinksInPath().path(percentEncoded: false)
        guard let files = FileManager.default.enumerator(at: folder.resolvingSymlinksInPath(),
                                                         includingPropertiesForKeys: keys) else { return }
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            // The enumerator hands back /var/… for /private/var/…; resolve so the prefix matches.
            let path = file.resolvingSymlinksInPath().path(percentEncoded: false)
            let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
            visit(relative.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                  Int64(values.totalFileAllocatedSize ?? 0), values.contentModificationDate)
        }
    }
}
