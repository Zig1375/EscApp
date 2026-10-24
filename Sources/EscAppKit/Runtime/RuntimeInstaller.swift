import Foundation

/// Installs a runtime from the manifest into `Runtime/<id>`.
///
/// Everything is assembled in a staging folder and moved into place in one step at the end, with a
/// `RUNTIME.json` marker written last. A runtime folder without the marker never counts as installed, so a
/// crash or a pulled network cable can't leave a half-installed Wine that games then try to use.
public struct RuntimeInstaller: Sendable {
    public enum Step: Sendable, Equatable {
        case downloading(RuntimeManifest.Component.Kind, received: Int64, total: Int64)
        case unpacking(RuntimeManifest.Component.Kind)
        case finishing
    }

    public static let markerName = "RUNTIME.json"

    let paths: AppPaths
    let downloader: Downloader

    public init(paths: AppPaths, downloader: Downloader = Downloader()) {
        self.paths = paths
        self.downloader = downloader
    }

    /// The runtime folder when it is fully installed.
    public func installed(_ runtime: RuntimeManifest.Runtime) -> URL? {
        let folder = paths.runtime(runtime.id)
        let marker = folder.appending(path: Self.markerName)
        guard let data = try? Data(contentsOf: marker),
              let recorded = try? JSONDecoder().decode(RuntimeManifest.Runtime.self, from: data),
              // Same files means the same runtime, even if the manifest later fixes a typo in a license name.
              recorded.components.map(\.sha256) == runtime.components.map(\.sha256)
        else { return nil }
        return folder
    }

    /// Removes staging folders an install left when the app quit or crashed halfway. Partial downloads stay,
    /// so the next install resumes them.
    public func removeLeftovers() {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(atPath: paths.runtimes.path)) ?? []
        for name in entries where name.hasPrefix(".staging-") {
            try? fileManager.removeItem(at: paths.runtimes.appending(path: name))
        }
    }

    /// Deletes every installed runtime but `current` (~1 GB each). An update replaces the old Wine rather than
    /// sitting next to it: games don't need it any more, because a bottle moves to the new runtime at its next
    /// launch and the move only needs the old *template* (`BottleManager.removeUnusedTemplates`). A runtime
    /// something still runs from (a game, a store client) stays until the next call.
    /// - Returns: the ids it removed.
    @discardableResult
    public func removeOlder(keeping current: String, busy: Set<String>? = nil) -> [String] {
        let busy = busy ?? runningRuntimes()
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(atPath: paths.runtimes.path)) ?? []
        var removed: [String] = []
        for name in Self.removable(entries, keeping: current, busy: busy)
        where (try? fileManager.removeItem(at: paths.runtimes.appending(path: name))) != nil {
            removed.append(name)
        }
        return removed
    }

    /// The runtime folders that can go: not hidden (staging, partial downloads), not `current`, not in use.
    static func removable(_ entries: [String], keeping current: String, busy: Set<String>) -> [String] {
        entries.filter { !$0.hasPrefix(".") && $0 != current && !busy.contains($0) }.sorted()
    }

    /// Runtimes some process on this Mac runs from: its executable lies inside `Runtime/<id>/`.
    func runningRuntimes() -> Set<String> {
        let root = paths.runtimes.resolvingSymlinksInPath().path(percentEncoded: false)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return Set(WineProcesses.allPIDs().compactMap { pid -> String? in
            guard let path = GameWindows.executablePath(of: pid), path.hasPrefix(prefix) else { return nil }
            return path.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
        })
    }

    @discardableResult
    public func install(
        _ runtime: RuntimeManifest.Runtime,
        progress: @escaping @Sendable (Step) -> Void = { _ in }
    ) async throws -> URL {
        if let folder = installed(runtime) { return folder }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.runtimes, withIntermediateDirectories: true)
        // Manifest ids never start with a dot, so this can't collide with a runtime.
        let staging = paths.runtimes.appending(path: ".staging-\(runtime.id)", directoryHint: .isDirectory)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            return try await assemble(runtime, in: staging, progress: progress)
        } catch {
            // Downloads stay in `Downloads/` so the next try resumes them; the half-built runtime goes.
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func assemble(
        _ runtime: RuntimeManifest.Runtime,
        in staging: URL,
        progress: @escaping @Sendable (Step) -> Void
    ) async throws -> URL {
        let fileManager = FileManager.default
        for component in runtime.components {
            let total = component.size
            let archive = try await downloader.fetch(component, into: paths.downloads) { received in
                progress(.downloading(component.kind, received: received, total: total))
            }
            try Task.checkCancellation()
            progress(.unpacking(component.kind))
            try await Self.unpack(archive, component: component, into: staging)
        }

        progress(.finishing)
        let marker = try JSONEncoder().encode(runtime)
        try marker.write(to: staging.appending(path: Self.markerName))
        let destination = paths.runtime(runtime.id)
        // A folder here without a matching marker is a broken or replaced install of the same id.
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: staging, to: destination)
        // The archives are ~200 MB together and are fetched again only for a new runtime. Anything else in
        // Downloads is left over from a runtime that's no longer wanted, so it goes too.
        try? fileManager.removeItem(at: paths.downloads)
        return destination
    }

    /// Unpacks into a scratch folder inside staging, then moves the manifest's `from` folder to `into`.
    /// bsdtar refuses `..` and absolute paths in archives and doesn't extract through symlinks, so a hostile
    /// archive stays inside the scratch folder; the hash check means it would have to be the pinned file anyway.
    static func unpack(_ archive: URL, component: RuntimeManifest.Component, into staging: URL) async throws {
        let fileManager = FileManager.default
        let scratch = staging.appending(path: ".unpack-\(component.kind.rawValue)", directoryHint: .isDirectory)
        try? fileManager.removeItem(at: scratch)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        try await ProcessRunner.check("/usr/bin/tar", ["-xf", archive.path, "-C", scratch.path])

        let source = component.from.isEmpty ? scratch : scratch.appending(path: component.from)
        guard fileManager.fileExists(atPath: source.path) else {
            throw InstallError.missingFolder(component.kind, component.from)
        }
        let destination = staging.appending(path: component.into)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw InstallError.destinationExists(component.kind, component.into)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)
    }
}

public enum InstallError: Error, Equatable, CustomStringConvertible {
    case missingFolder(RuntimeManifest.Component.Kind, String)
    case destinationExists(RuntimeManifest.Component.Kind, String)

    public var description: String {
        switch self {
        case let .missingFolder(kind, folder):
            "The \(kind.rawValue) download doesn't contain the expected folder “\(folder)”."
        case let .destinationExists(kind, folder):
            "Two parts of the runtime want the same place (\(kind.rawValue) → \(folder))."
        }
    }
}
