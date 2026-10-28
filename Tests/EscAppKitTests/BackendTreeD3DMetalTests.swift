@testable import EscAppKit
import Foundation
import Testing

@Suite struct BackendTreeD3DMetalTests {
    /// A runtime and a D3DMetal laid out like Apple's: the tree gets D3DMetal's DLLs, keeps the .so files as links
    /// to libd3dshared.dylib and reaches Apple's files through `lib/external`, without copying them.
    @Test func treeLinksToTheInstalledD3DMetal() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "d3dm-tree-\(UUID().uuidString)",
                                                                     directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appending(path: "Runtime/wine-11.20", directoryHint: .isDirectory)
        let d3dmetal = root.appending(path: "D3DMetal/3.0", directoryHint: .isDirectory)
        for (file, text) in [("wine/bin/wine", "wine"), ("wine/lib/wine/x86_64-windows/d3d12.dll", "vkd3d")] {
            try write(text, to: runtime.appending(path: file))
        }
        for (file, text) in [("lib/external/libd3dshared.dylib", "apple"),
                             ("lib/wine/x86_64-windows/d3d12.dll", "apple d3d12"),
                             ("lib/wine/x86_64-windows/nvngx-on-metalfx.dll", "metalfx")] {
            try write(text, to: d3dmetal.appending(path: file))
        }
        let unix = d3dmetal.appending(path: "lib/wine/x86_64-unix", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unix, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: unix.appending(path: "d3d12.so").path,
                                                   withDestinationPath: "../../external/libd3dshared.dylib")

        let tree = try BackendTree.wine(for: .d3dmetal, runtimeFolder: runtime, d3dmetal: d3dmetal).root
        #expect(tree.lastPathComponent == "wine-d3dmetal-3.0")
        let lib = tree.appending(path: "lib/wine")
        let dll = try String(contentsOf: lib.appending(path: "x86_64-windows/d3d12.dll"), encoding: .utf8)
        #expect(dll == "apple d3d12")
        #expect(try String(contentsOf: lib.appending(path: "x86_64-unix/d3d12.so"), encoding: .utf8) == "apple")
        let metalFX = lib.appending(path: "x86_64-windows/nvngx-on-metalfx.dll")
        #expect(!FileManager.default.fileExists(atPath: metalFX.path))
        // The runtime's own Wine is untouched.
        let plain = runtime.appending(path: "wine/lib/wine/x86_64-windows/d3d12.dll")
        #expect(try String(contentsOf: plain, encoding: .utf8) == "vkd3d")
    }

    @Test func noD3DMetalNoTree() {
        let runtime = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString)")
        #expect(throws: BottleError.self) { try BackendTree.wine(for: .d3dmetal, runtimeFolder: runtime) }
    }

    @Test func runtimeSaysWhetherItLoadsD3DMetal() throws {
        let runtime = FileManager.default.temporaryDirectory.appending(path: "build-\(UUID().uuidString)",
                                                                        directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: runtime) }
        func record(_ features: [String]?) throws {
            let wine = RuntimeManifest.Component(kind: .wine, version: "11.20", url: URL(string: "https://x")!,
                                                 sha256: "0", size: 1, license: "LGPL-2.1-or-later", from: "wine",
                                                 into: "wine", features: features)
            let manifest = RuntimeManifest.Runtime(id: "wine-11.20", minApp: Version("0.1.0")!,
                                                   minMacOS: Version("15.0")!, components: [wine])
            try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
            try JSONEncoder().encode(manifest).write(to: runtime.appending(path: RuntimeInstaller.markerName))
        }
        try record(["osync"])
        #expect(!BackendTree.supportsD3DMetal(runtimeFolder: runtime))
        try record(["osync", "d3dmetal"])
        #expect(BackendTree.supportsD3DMetal(runtimeFolder: runtime))
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
