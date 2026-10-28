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

    /// The Wine to run for `backend`, building its tree the first time. `d3dmetal` is the installed D3DMetal's
    /// folder (`D3DMetal.installed`), needed only for that backend.
    public static func wine(for backend: GraphicsBackend, runtimeFolder: URL, d3dmetal: URL? = nil) throws -> Wine {
        if backend == .d3dmetal { return try d3dmetalWine(runtimeFolder: runtimeFolder, d3dmetal: d3dmetal) }
        guard let component = backend.component else { return Wine(runtimeFolder: runtimeFolder) }
        let tree = runtimeFolder.appending(path: "wine-\(backend.rawValue)", directoryHint: .isDirectory)
        if isBuilt(tree) { return Wine(root: tree) }
        try build(tree, from: runtimeFolder.appending(path: "wine", directoryHint: .isDirectory),
                  overlay: runtimeFolder.appending(path: component.rawValue, directoryHint: .isDirectory),
                  backend: backend)
        return Wine(root: tree)
    }

    static func isBuilt(_ tree: URL) -> Bool {
        FileManager.default.fileExists(atPath: tree.appending(path: markerName).path)
    }

    /// `overlay` mirrors Wine's `lib/wine`: `x86_64-windows/d3d11.dll` replaces `lib/wine/x86_64-windows/d3d11.dll`.
    static func build(_ tree: URL, from wine: URL, overlay: URL, backend: GraphicsBackend) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: overlay.path) else { throw BottleError.runtimeMissing(backend.rawValue) }
        // Each build has its own staging folder: two games started at once on a new runtime (or a launch and a
        // warm-up) both build the tree, and a shared folder made one delete the other's half-copied files.
        let staging = tree.deletingLastPathComponent()
            .appending(path: ".staging-\(tree.lastPathComponent)-\(UUID().uuidString)")
        BottleManager.removeStaleStaging(in: tree.deletingLastPathComponent())
        do {
            try BottleManager.clone(wine, to: staging)
            var files: [String] = []
            let libraries = staging.appending(path: "lib/wine", directoryHint: .isDirectory)
            guard let walker = fileManager.enumerator(at: overlay, includingPropertiesForKeys: [.isRegularFileKey])
            else { throw BottleError.runtimeMissing(backend.rawValue) }
            for case let file as URL in walker
            where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                // Both resolved: the enumerator hands out `/private/var/…` for a folder given as `/var/…`.
                let relative = String(file.resolvingSymlinksInPath().path(percentEncoded: false)
                    .dropFirst(overlay.resolvingSymlinksInPath().path(percentEncoded: false).count))
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
            // A finished tree is never replaced: a game may be running from it. One without its marker is left
            // over from an older build. The move fails if another build published first; the catch takes that.
            if fileManager.fileExists(atPath: tree.path), !isBuilt(tree) { try? fileManager.removeItem(at: tree) }
            try fileManager.moveItem(at: staging, to: tree)
        } catch {
            try? fileManager.removeItem(at: staging)
            if isBuilt(tree) { return }
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
        case .wined3d, .d3dmetal: nil
        }
    }
}

extension BackendTree {
    /// The runtime feature that says a Wine build can run D3DMetal (EscApp-Runtime's patches 0010 and 0011).
    static let d3dmetalFeature = "d3dmetal"

    /// Whether this runtime's Wine can run D3DMetal, from its `RUNTIME.json`. Without the build's support,
    /// D3DMetal's d3d12.dll fails to initialize and the game never starts.
    public static func supportsD3DMetal(runtimeFolder: URL) -> Bool {
        Wine(runtimeFolder: runtimeFolder).runtime?.wineHas(d3dmetalFeature) ?? false
    }

    /// `wine-d3dmetal-<version>`: Wine with D3DMetal's DLLs in `lib/wine` and `lib/external` linking to the
    /// installed D3DMetal, where its `.so` files point (`../../external/libd3dshared.dylib`). Apple's files stay in
    /// one place, untouched and signed; the tree only holds links to them. A new D3DMetal gets a new tree, since a
    /// game may still be running from the old one.
    static func d3dmetalWine(runtimeFolder: URL, d3dmetal: URL?) throws -> Wine {
        let lib = d3dmetal?.appending(path: "lib", directoryHint: .isDirectory)
        guard let lib, let d3dmetal,
              FileManager.default.fileExists(atPath: lib.appending(path: "external/libd3dshared.dylib").path)
        else { throw BottleError.runtimeMissing(GraphicsBackend.d3dmetal.rawValue) }
        let tree = runtimeFolder.appending(path: "wine-d3dmetal-\(d3dmetal.lastPathComponent)",
                                           directoryHint: .isDirectory)
        if isBuilt(tree) { return Wine(root: tree) }
        let fileManager = FileManager.default
        let staging = tree.deletingLastPathComponent()
            .appending(path: ".staging-\(tree.lastPathComponent)-\(UUID().uuidString)")
        BottleManager.removeStaleStaging(in: tree.deletingLastPathComponent())
        do {
            try BottleManager.clone(runtimeFolder.appending(path: "wine", directoryHint: .isDirectory), to: staging)
            var files: [String] = []
            for arch in ["x86_64-windows", "x86_64-unix"] {
                let from = lib.appending(path: "wine/\(arch)", directoryHint: .isDirectory)
                try fileManager.createDirectory(at: staging.appending(path: "lib/wine/\(arch)"),
                                                withIntermediateDirectories: true)
                for name in try fileManager.contentsOfDirectory(atPath: from.path) where d3dmetalCopies(name) {
                    let target = staging.appending(path: "lib/wine/\(arch)/\(name)")
                    // Remove first: the target is a clone, and replacing it must not write through to the original.
                    try? fileManager.removeItem(at: target)
                    // copyItem copies a link as a link, so the .so files still point at libd3dshared.dylib.
                    try fileManager.copyItem(at: from.appending(path: name), to: target)
                    files.append("lib/wine/\(arch)/\(name)")
                }
            }
            try fileManager.createSymbolicLink(at: staging.appending(path: "lib/external"),
                                               withDestinationURL: lib.appending(path: "external"))
            files.append("lib/external")
            let marker = try JSONEncoder().encode(Marker(backend: .d3dmetal, files: files.sorted()))
            try marker.write(to: staging.appending(path: markerName))
            if fileManager.fileExists(atPath: tree.path), !isBuilt(tree) { try? fileManager.removeItem(at: tree) }
            try fileManager.moveItem(at: staging, to: tree)
        } catch {
            try? fileManager.removeItem(at: staging)
            if isBuilt(tree) { return Wine(root: tree) }
            throw error
        }
        return Wine(root: tree)
    }

    /// D3DMetal's DLLs that go into Wine. Its MetalFX stand-in for DLSS (`nvngx-on-metalfx`) stays out: Apple's
    /// notes call it experimental, and it only works renamed and copied into the bottle.
    static func d3dmetalCopies(_ name: String) -> Bool {
        (name.hasSuffix(".dll") || name.hasSuffix(".so")) && !name.hasPrefix("nvngx")
    }
}
