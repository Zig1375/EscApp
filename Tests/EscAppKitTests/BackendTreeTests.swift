@testable import EscAppKit
import Foundation
import Testing

@Suite struct BackendTreeTests {
    /// Two games started at once on a new runtime both build its DXVK tree; before each build had its own staging
    /// folder, one deleted the other's half-made copy ("File exists", then a missing `bin/wine`).
    @Test func buildsStartedTogetherAllGetTheTree() async throws {
        let runtime = FileManager.default.temporaryDirectory.appending(path: "tree-\(UUID().uuidString)",
                                                                        directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: runtime) }
        for (file, text) in [("wine/bin/wine", "wine"), ("wine/lib/wine/x86_64-windows/d3d11.dll", "wined3d"),
                             ("dxvk/x86_64-windows/d3d11.dll", "dxvk")] {
            let url = runtime.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let roots = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<6 {
                group.addTask { try BackendTree.wine(for: .dxvk, runtimeFolder: runtime).root }
            }
            return try await group.reduce(into: [URL]()) { $0.append($1) }
        }
        #expect(Set(roots.map(\.lastPathComponent)) == ["wine-dxvk"])
        let tree = runtime.appending(path: "wine-dxvk")
        #expect(FileManager.default.fileExists(atPath: tree.appending(path: "bin/wine").path))
        let dll = try String(contentsOf: tree.appending(path: "lib/wine/x86_64-windows/d3d11.dll"), encoding: .utf8)
        #expect(dll == "dxvk")
        let left = try FileManager.default.contentsOfDirectory(atPath: runtime.path).filter { $0.hasPrefix(".") }
        #expect(left.isEmpty)
    }
}
