@testable import EscAppKit
import Foundation
import Testing

@Suite struct MsyncTests {
    @Test func theVariableIsSetOnlyWhenAsked() {
        #expect(WineEnvironment.make(host: [:], bottle: "/b")["WINEMSYNC"] == nil)
        #expect(WineEnvironment.make(host: [:], bottle: "/b", msync: true)["WINEMSYNC"] == "1")
        // A stray value from the user's shell never reaches Wine.
        #expect(WineEnvironment.make(host: ["WINEMSYNC": "1"], bottle: "/b")["WINEMSYNC"] == nil)
    }

    @Test func aRunningProcessIsReadTheWayWineReadsIt() {
        #expect(WineEnvironment.msyncIsOn(["WINEMSYNC": "1"]))
        #expect(WineEnvironment.msyncIsOn(["WINEMSYNC": "2"]))
        #expect(!WineEnvironment.msyncIsOn(["WINEMSYNC": "0"]))
        #expect(!WineEnvironment.msyncIsOn(["WINEMSYNC": ""]))
        #expect(!WineEnvironment.msyncIsOn([:]))
    }

    @Test func theBundledListTurnsItOnOnlyForBuildsThatHaveIt() throws {
        let manifest = try RuntimeManifest.bundled()
        let newest = try #require(manifest.runtimes.last)
        #expect(newest.wineHas("msync"))
        #expect(!manifest.runtimes.dropLast().contains { $0.wineHas("msync") })
    }

    @Test func aManifestWithoutFeaturesStillReads() throws {
        let sha = String(repeating: "a", count: 64)
        let json = """
            {"format": 1, "runtimes": [{"id": "r", "minApp": "0.1.0", "minMacOS": "15.0", "components": [
              {"kind": "wine", "version": "1", "url": "https://example.com/w.tar.xz", "sha256": "\(sha)",
               "size": 1, "license": "LGPL-2.1-or-later", "from": "", "into": "wine"}]}]}
            """
        let manifest = try RuntimeManifest.decode(Data(json.utf8))
        #expect(manifest.runtimes[0].components[0].features == nil)
        #expect(!manifest.runtimes[0].wineHas("msync"))
    }

    @Test func everyTreeOfARuntimeFollowsItsMarker() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "msync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plain = Wine(runtimeFolder: folder)
        let dxvk = Wine(root: folder.appending(path: "wine-dxvk", directoryHint: .isDirectory))
        #expect(!plain.supportsMsync)

        var runtime = try #require(RuntimeManifest.bundled().runtimes.last)
        try JSONEncoder().encode(runtime).write(to: folder.appending(path: RuntimeInstaller.markerName))
        #expect(plain.supportsMsync && dxvk.supportsMsync)

        runtime.components[0].features = nil
        try JSONEncoder().encode(runtime).write(to: folder.appending(path: RuntimeInstaller.markerName))
        #expect(!dxvk.supportsMsync)
    }

    @Test func aPlayerCanTurnItOffForOneGameButNotForAStore() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "msync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let runtime = try #require(RuntimeManifest.bundled().runtimes.last)
        try JSONEncoder().encode(runtime).write(to: folder.appending(path: RuntimeInstaller.markerName))
        let wine = Wine(runtimeFolder: folder)

        var game = GameRecord(id: .make(), name: "G", executable: "/g.exe", folder: "/", hasMarker: false,
                              addedAt: Date())
        #expect(WineEnvironment.msync(for: game, wine: wine))
        #expect(WineEnvironment.msync(for: nil, wine: wine))
        game.msync = false
        #expect(!WineEnvironment.msync(for: game, wine: wine))
        game.store = .steam
        #expect(WineEnvironment.msync(for: game, wine: wine))
        #expect(!WineEnvironment.msync(for: nil, wine: Wine(root: URL(filePath: "/nowhere/wine"))))
    }
}
