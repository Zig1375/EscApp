import Foundation

/// A Wine tree per graphics backend, so a game picks DXVK or DXMT just by which `wine` it runs.
///
/// Neither DXVK nor DXMT can be plugged into Gcenx's Wine from outside: it has no `WINEDLLPATH_PREPEND`, plain
/// `WINEDLLPATH` is searched after Wine's own DLLs, and both projects ship "builtin" DLLs, which Wine ignores in a
/// bottle's system32 and loads from its own folder instead. So `wine-dxvk` and `wine-dxmt` are APFS clones of the
/// runtime's `wine` folder with the backend's DLLs (and DXMT's `winemetal.so`) put into `lib/wine`. A clone costs
/// almost nothing, the plain `wine` stays untouched for WineD3D, and no bottle ever holds graphics DLLs.
public enum BackendTree {
    static let markerName = ".escapp-backend.json"

    struct Marker: Codable {
        var backend: GraphicsBackend
        /// Files replaced or added, relative to the tree, for anyone checking what differs from plain Wine.
        var files: [String]
    }

    /// The Wine to run for `backend`, building its tree the first time.
    public static func wine(for backend: GraphicsBackend, runtimeFolder: URL) throws -> Wine {
        guard let component = backend.component else { return Wine(runtimeFolder: runtimeFolder) }
        let tree = runtimeFolder.appending(path: "wine-\(backend.rawValue)", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: tree.appending(path: markerName).path) {
            return Wine(root: tree)
        }
        try build(tree, from: runtimeFolder.appending(path: "wine", directoryHint: .isDirectory),
                  overlay: runtimeFolder.appending(path: component.rawValue, directoryHint: .isDirectory),
                  backend: backend)
        return Wine(root: tree)
    }

    /// `overlay` mirrors Wine's `lib/wine`: `x86_64-windows/d3d11.dll` replaces `lib/wine/x86_64-windows/d3d11.dll`.
    static func build(_ tree: URL, from wine: URL, overlay: URL, backend: GraphicsBackend) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: overlay.path) else { throw BottleError.runtimeMissing(backend.rawValue) }
        let staging = tree.deletingLastPathComponent().appending(path: ".staging-\(tree.lastPathComponent)")
        try? fileManager.removeItem(at: staging)
        do {
            try BottleManager.clone(wine, to: staging)
            var files: [String] = []
            let libraries = staging.appending(path: "lib/wine", directoryHint: .isDirectory)
            guard let walker = fileManager.enumerator(at: overlay, includingPropertiesForKeys: [.isRegularFileKey])
            else { throw BottleError.runtimeMissing(backend.rawValue) }
            for case let file as URL in walker
            where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                let relative = String(file.path(percentEncoded: false)
                    .dropFirst(overlay.path(percentEncoded: false).count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let target = libraries.appending(path: relative)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                // Remove first: the target is a clone, and replacing it must not write through to the original.
                try? fileManager.removeItem(at: target)
                try fileManager.copyItem(at: file, to: target)
                files.append("lib/wine/" + relative)
            }
            let marker = try JSONEncoder().encode(Marker(backend: backend, files: files.sorted()))
            try marker.write(to: staging.appending(path: markerName))
            try? fileManager.removeItem(at: tree)
            try fileManager.moveItem(at: staging, to: tree)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }
}

extension BackendTree {
    /// Files a backend needs inside the bottle itself. DXMT's d3d11 and dxgi import `winemetal.dll`, and Wine only
    /// finds a builtin DLL through a stub in the bottle's system folder; `wineboot` makes those stubs only for DLLs
    /// that were in Wine's folder when the template was built, which `winemetal.dll` isn't. The stub is a copy of
    /// the builtin DLL, exactly what wineboot itself would write.
    public static func prepareBottle(_ bottle: URL, for backend: GraphicsBackend, wine: Wine) throws {
        guard backend == .dxmt else { return }
        let fileManager = FileManager.default
        let windows = bottle.appending(path: "drive_c/windows", directoryHint: .isDirectory)
        for (arch, folder) in [("x86_64-windows", "system32"), ("i386-windows", "syswow64")] {
            let stub = windows.appending(path: "\(folder)/winemetal.dll")
            let builtin = wine.root.appending(path: "lib/wine/\(arch)/winemetal.dll")
            guard !fileManager.fileExists(atPath: stub.path), fileManager.fileExists(atPath: builtin.path),
                  fileManager.fileExists(atPath: stub.deletingLastPathComponent().path) else { continue }
            try fileManager.copyItem(at: builtin, to: stub)
        }
    }
}

extension GraphicsBackend {
    /// The runtime component that carries this backend's DLLs; nil for Wine's own WineD3D.
    var component: RuntimeManifest.Component.Kind? {
        switch self {
        case .dxvk: .dxvk
        case .dxmt: .dxmt
        case .wined3d: nil
        }
    }
}
