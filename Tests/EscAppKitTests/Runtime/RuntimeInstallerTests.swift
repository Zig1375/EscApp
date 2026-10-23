@testable import EscAppKit
import Foundation
import Testing

@Suite struct RuntimeInstallerTests {
    func setUp() throws -> (TempFolder, AppPaths) {
        let temp = try TempFolder()
        return (temp, AppPaths(root: temp.url.appending(path: "EscApp"), games: temp.url.appending(path: "Games")))
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

    @Test func aFolderWithoutMarkerIsNotInstalled() throws {
        let (_, paths) = try setUp()
        let runtime = RuntimeManifest.Runtime(id: "test-3", minApp: version("0.1"), minMacOS: version("15"),
                                              components: [])
        try FileManager.default.createDirectory(at: paths.runtime("test-3").appending(path: "wine"),
                                                withIntermediateDirectories: true)
        #expect(RuntimeInstaller(paths: paths).installed(runtime) == nil)
    }
}

@Suite struct RosettaTests {
    @Test func checksTheRuntimeFile() {
        #expect(Rosetta.isInstalled { $0 == Rosetta.runtimeFile })
        #expect(!Rosetta.isInstalled { _ in false })
    }
}
