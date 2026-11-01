import Foundation
@testable import MagicKettleKit
import Testing

@Suite struct D3DMetalTests {
    /// What Apple's "Evaluation environment for Windows games" 3.0 image holds (4.0 beta 3 differs only in DLLs).
    static let image: Set<String> = [
        "License.rtf", "Acknowledgements.rtf", "Read Me.rtf", "redist", "redist/lib", "redist/lib/external",
        "redist/lib/external/D3DMetal.framework", "redist/lib/external/D3DMetal.framework/Resources",
        "redist/lib/external/libd3dshared.dylib", "redist/lib/wine/x86_64-windows/d3d12.dll",
        "redist/lib/wine/x86_64-windows/dxgi.dll", "redist/lib/wine/x86_64-windows/d3d11.dll",
        "redist/lib/wine/x86_64-unix/d3d12.so", "redist/lib/wine/x86_64-unix/dxgi.so",
    ]

    @Test func findsTheLibraryFolderInApplesImage() {
        #expect(D3DMetal.libFolder(in: Self.image) == "redist/lib")
    }

    @Test func findsItWhereverALaterImagePutsIt() {
        let moved = Set(Self.image.map { $0.replacingOccurrences(of: "redist/lib", with: "D3DMetal/redist/lib") })
        #expect(D3DMetal.libFolder(in: moved) == "D3DMetal/redist/lib")
    }

    /// Apple's other download, the porting tools, has no D3DMetal; neither does a framework without its DLLs.
    @Test func refusesAnImageWithoutAllOfIt() {
        #expect(D3DMetal.libFolder(in: ["License.rtf", "Tools/metal-shaderconverter"]) == nil)
        #expect(D3DMetal.libFolder(in: Self.image.filter { !$0.hasSuffix("d3d12.dll") }) == nil)
    }

    @Test func readsTheFrameworkVersion() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "4.0b3"],
                                                       format: .xml, options: 0)
        #expect(D3DMetal.version(infoPlist: plist) == "4.0b3")
        #expect(D3DMetal.version(infoPlist: Data("not a plist".utf8)) == nil)
    }

    /// With a real image from Apple (`MAGICKETTLE_D3DMETAL_IMAGE=<dmg>`; nothing of Apple's is in the repository):
    /// the import finds it, checks Apple's signature and installs it in a scratch home.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAGICKETTLE_D3DMETAL_IMAGE"] != nil))
    func importsApplesImage() async throws {
        let image = URL(filePath: try #require(ProcessInfo.processInfo.environment["MAGICKETTLE_D3DMETAL_IMAGE"]))
        let root = FileManager.default.temporaryDirectory.appending(path: "d3dm-\(UUID().uuidString)",
                                                                     directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root, games: root.appending(path: "Games"))
        let candidate = try await D3DMetal.prepare(image: image, paths: paths)
        #expect(FileManager.default.fileExists(atPath: candidate.license.path))
        try D3DMetal.install(candidate, paths: paths)
        let installed = try #require(D3DMetal.installed(paths: paths))
        #expect(installed.info.version == candidate.version)
        let link = installed.folder.appending(path: "lib/wine/x86_64-unix/d3d12.so")
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(target == "../../external/libd3dshared.dylib")
        try await D3DMetal.checkSignatures(in: installed.folder.appending(path: "lib"))
    }
}
