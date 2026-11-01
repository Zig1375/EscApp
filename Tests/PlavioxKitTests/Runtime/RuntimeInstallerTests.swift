import Foundation
@testable import PlavioxKit
import Testing

@Suite struct RuntimeInstallerTests {
    func setUp() throws -> (TempFolder, AppPaths) {
        let temp = try TempFolder()
        return (temp, AppPaths(root: temp.url.appending(path: "Plaviox"), games: temp.url.appending(path: "Games")))
    }

    func publish(_ data: Data, in temp: TempFolder) throws -> URL {
        let url = temp.url.appending(path: "srv-\(UUID().uuidString).tar.gz")
        try data.write(to: url)
        return url
    }

    @Test func installsComponentsIntoPlaceAndMarksTheRuntime() async throws {
        let (temp, paths) = try setUp()
        let wine = try makeArchive(["Wine.app/Contents/Resources/wine/bin/wine": "#!wine",
                                    "Wine.app/Contents/Info.plist": "plist"], in: temp.url)
        let mono = try makeArchive(["wine-mono-1/bin/mono.dll": "mono"], in: temp.url)
        let runtime = RuntimeManifest.Runtime(
            id: "test-1", minApp: version("0.1"), minMacOS: version("15"),
            components: [
                component(url: try publish(wine, in: temp), data: wine, from: "Wine.app/Contents/Resources/wine",
                          into: "wine"),
                component(url: try publish(mono, in: temp), data: mono, kind: .mono, from: "wine-mono-1",
                          into: "wine/share/wine/mono/wine-mono-1"),
            ])
        let installer = RuntimeInstaller(paths: paths)
        #expect(installer.installed(runtime) == nil)

        let steps = Log()
        let folder = try await installer.install(runtime) { steps.add("\($0)") }

        #expect(installer.installed(runtime) == folder)
        #expect(try String(contentsOf: folder.appending(path: "wine/bin/wine"), encoding: .utf8) == "#!wine")
        let monoDLL = folder.appending(path: "wine/share/wine/mono/wine-mono-1/bin/mono.dll")
        #expect(FileManager.default.fileExists(atPath: monoDLL.path))
        // Only the `from` folder is taken, not the rest of the app bundle.
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "wine/Info.plist").path))
        // Staging and downloaded archives are gone.
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.runtimes.path) == ["test-1"])
        #expect(!FileManager.default.fileExists(atPath: paths.downloads.path))
        #expect(steps.values.contains("finishing"))
    }

    @Test func aFailedInstallLeavesNoRuntime() async throws {
        let (temp, paths) = try setUp()
        let wine = try makeArchive(["other/bin/wine": "x"], in: temp.url)
        let runtime = RuntimeManifest.Runtime(
            id: "test-2", minApp: version("0.1"), minMacOS: version("15"),
            components: [component(url: try publish(wine, in: temp), data: wine, from: "missing", into: "wine")])
        let installer = RuntimeInstaller(paths: paths)

        await #expect(throws: InstallError.missingFolder(.wine, "missing")) {
            try await installer.install(runtime)
        }
        #expect(installer.installed(runtime) == nil)
        // Nothing is left behind, not even the staging folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.runtimes.path).isEmpty)
    }

    @Test func leftoversFromAnInterruptedInstallAreRemoved() throws {
        let (_, paths) = try setUp()
        let staging = paths.runtimes.appending(path: ".staging-r1")
        try FileManager.default.createDirectory(at: staging.appending(path: "wine"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.runtime("r0"), withIntermediateDirectories: true)
        RuntimeInstaller(paths: paths).removeLeftovers()
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.runtimes.path) == ["r0"])
    }

    @Test func anUpdateRemovesOlderRuntimesNothingRunsFrom() throws {
        #expect(RuntimeInstaller.removable([".staging-r3", "r1", "r2", "r3", ".DS_Store"], keeping: "r3",
                                           busy: ["r2"]) == ["r1"])

        let (_, paths) = try setUp()
        for id in ["r1", "r2", "r3"] {
            try FileManager.default.createDirectory(at: paths.runtime(id).appending(path: "wine"),
                                                    withIntermediateDirectories: true)
        }
        #expect(RuntimeInstaller(paths: paths).removeOlder(keeping: "r3", busy: []) == ["r1", "r2"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.runtimes.path) == ["r3"])
    }

    @Test func aFolderWithoutMarkerIsNotInstalled() throws {
        let (_, paths) = try setUp()
        let runtime = RuntimeManifest.Runtime(id: "test-3", minApp: version("0.1"), minMacOS: version("15"),
                                              components: [])
        try FileManager.default.createDirectory(at: paths.runtime("test-3").appending(path: "wine"),
                                                withIntermediateDirectories: true)
        #expect(RuntimeInstaller(paths: paths).installed(runtime) == nil)
    }

    @Test func anUpdateTakesUnchangedComponentsFromTheInstalledRuntime() async throws {
        let (temp, paths) = try setUp()
        let oldWine = try makeArchive(["bin/wine": "old"], in: temp.url)
        let newWine = try makeArchive(["bin/wine": "new"], in: temp.url)
        let dxvk = try makeArchive(["x64/d3d11.dll": "dxvk"], in: temp.url)
        let dxvkURL = try publish(dxvk, in: temp)
        let installer = RuntimeInstaller(paths: paths)
        try await installer.install(RuntimeManifest.Runtime(
            id: "r1", minApp: version("0.1"), minMacOS: version("15"),
            components: [component(url: try publish(oldWine, in: temp), data: oldWine),
                         component(url: dxvkURL, data: dxvk, kind: .dxvk, into: "dxvk")]))

        // DXVK can't be downloaded any more, so the update only works by taking the installed copy.
        try FileManager.default.removeItem(at: dxvkURL)
        let folder = try await installer.install(RuntimeManifest.Runtime(
            id: "r2", minApp: version("0.1"), minMacOS: version("15"),
            components: [component(url: try publish(newWine, in: temp), data: newWine),
                         component(url: dxvkURL, data: dxvk, kind: .dxvk, into: "dxvk")]))

        #expect(try String(contentsOf: folder.appending(path: "wine/bin/wine"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: folder.appending(path: "dxvk/x64/d3d11.dll"), encoding: .utf8) == "dxvk")
    }

    @Test func onlyTheSameFileInTheSamePlaceIsReused() throws {
        let url = try #require(URL(string: "https://example.com/a.tar.gz"))
        let folder = URL(filePath: "/R/r1")
        func part(_ data: String, kind: RuntimeManifest.Component.Kind = .wine, from: String = "",
                  into: String = "wine") -> RuntimeManifest.Component {
            component(url: url, data: Data(data.utf8), kind: kind, from: from, into: into)
        }
        func runtime(_ components: [RuntimeManifest.Component]) -> [(folder: URL, runtime: RuntimeManifest.Runtime)] {
            [(folder, RuntimeManifest.Runtime(id: "r1", minApp: version("0.1"), minMacOS: version("15"),
                                              components: components))]
        }

        #expect(RuntimeInstaller.reusable(part("dxvk", kind: .dxvk, into: "dxvk"),
                                          from: runtime([part("wine"), part("dxvk", kind: .dxvk, into: "dxvk")]))
                == folder.appending(path: "dxvk", directoryHint: .isDirectory))
        #expect(RuntimeInstaller.reusable(part("wine"), from: runtime([part("other")])) == nil)
        #expect(RuntimeInstaller.reusable(part("wine"), from: runtime([part("wine", from: "Wine.app")])) == nil)
        #expect(RuntimeInstaller.reusable(part("wine"), from: runtime([part("wine", into: "wine2")])) == nil)
        // Wine with Wine Mono unpacked inside it is more than this Wine.
        #expect(RuntimeInstaller.reusable(part("wine"), from: runtime([
            part("wine"), part("mono", kind: .mono, into: "wine/share/wine/mono"),
        ])) == nil)
        #expect(RuntimeInstaller.reusable(part("wine"), from: []) == nil)
    }
}

@Suite struct RosettaTests {
    @Test func checksTheRuntimeFile() {
        #expect(Rosetta.isInstalled { $0 == Rosetta.runtimeFile })
        #expect(!Rosetta.isInstalled { _ in false })
    }
}
