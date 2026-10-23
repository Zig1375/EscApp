import Foundation

/// What is installed compared with what the component list offers. Pure, so the components screen and the
/// update banner are decided by tested code.
public struct RuntimeCatalog: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case notInstalled(newest: RuntimeManifest.Runtime)
        case upToDate(RuntimeManifest.Runtime)
        case updateAvailable(current: RuntimeManifest.Runtime, newest: RuntimeManifest.Runtime)
        /// Neither the list nor anything installed suits this Mac and app version.
        case unavailable
    }

    public struct Change: Sendable, Equatable {
        public var kind: RuntimeManifest.Component.Kind
        /// `nil` when the newer runtime adds this component.
        public var oldVersion: String?
        /// `nil` when the newer runtime drops it.
        public var newVersion: String?
    }

    public var installed: [RuntimeManifest.Runtime]
    public var status: Status

    public init(installed: [RuntimeManifest.Runtime], manifest: RuntimeManifest, app: Version, macOS: Version) {
        self.installed = installed
        let newest = manifest.newest(forApp: app, macOS: macOS)
        let order = Dictionary(manifest.runtimes.enumerated().map { ($1.id, $0) }) { first, _ in first }
        // The installed runtime that is newest by list order; one the list no longer knows sorts oldest.
        let current = installed.max { (order[$0.id] ?? -1) < (order[$1.id] ?? -1) }

        switch (current, newest) {
        case (nil, nil):
            status = .unavailable
        case let (nil, newest?):
            status = .notInstalled(newest: newest)
        case let (current?, nil):
            status = .upToDate(current)
        case let (current?, newest?):
            if let installedNewest = installed.first(where: { $0.id == newest.id }) {
                status = .upToDate(installedNewest)
            } else if (order[current.id] ?? -1) > (order[newest.id] ?? -1) {
                // Installed something newer than this app may use (e.g. after a downgrade): keep it.
                status = .upToDate(current)
            } else {
                status = .updateAvailable(current: current, newest: newest)
            }
        }
    }

    /// The installed runtime games run on now; nil when none is installed.
    public var current: RuntimeManifest.Runtime? {
        switch status {
        case let .upToDate(runtime), let .updateAvailable(runtime, _): runtime
        case .notInstalled, .unavailable: nil
        }
    }

    public var updateAvailable: Bool {
        if case .updateAvailable = status { return true }
        return false
    }

    /// Component by component, what an update changes. Unchanged components are left out.
    public static func changes(from old: RuntimeManifest.Runtime, to new: RuntimeManifest.Runtime) -> [Change] {
        var result: [Change] = []
        for component in new.components {
            let previous = old.components.first { $0.kind == component.kind }
            if previous?.sha256 != component.sha256 {
                result.append(Change(kind: component.kind, oldVersion: previous?.version,
                                     newVersion: component.version))
            }
        }
        for component in old.components where !new.components.contains(where: { $0.kind == component.kind }) {
            result.append(Change(kind: component.kind, oldVersion: component.version, newVersion: nil))
        }
        return result
    }
}

extension RuntimeInstaller {
    /// Every fully installed runtime, read from the markers in `Runtime/`.
    public func installedRuntimes() -> [RuntimeManifest.Runtime] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: paths.runtimes, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: Self.markerName)),
                  let runtime = try? JSONDecoder().decode(RuntimeManifest.Runtime.self, from: data),
                  runtime.id == folder.lastPathComponent
            else { return nil }
            return runtime
        }
        .sorted { $0.id < $1.id }
    }

    /// Real space on disk, counting each file once.
    public func diskSize(of runtime: RuntimeManifest.Runtime) -> Int64 {
        let folder = paths.runtime(runtime.id)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}
