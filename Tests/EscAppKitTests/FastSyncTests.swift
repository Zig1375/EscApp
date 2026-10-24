@testable import EscAppKit
import Foundation
import Testing

@Suite struct FastSyncTests {
    @Test func theVariableIsSetOnlyWhenAsked() {
        #expect(WineEnvironment.make(host: [:], bottle: "/b")["WINEOSYNC"] == nil)
        #expect(WineEnvironment.make(host: [:], bottle: "/b", fastSync: true)["WINEOSYNC"] == "1")
        // A stray value from the user's shell never reaches Wine.
        #expect(WineEnvironment.make(host: ["WINEOSYNC": "1"], bottle: "/b")["WINEOSYNC"] == nil)
    }

    @Test func aRunningProcessIsReadTheWayWineReadsIt() {
        #expect(WineEnvironment.fastSyncIsOn(["WINEOSYNC": "1"]))
        #expect(WineEnvironment.fastSyncIsOn(["WINEOSYNC": "2"]))
        #expect(!WineEnvironment.fastSyncIsOn(["WINEOSYNC": "0"]))
        #expect(!WineEnvironment.fastSyncIsOn(["WINEOSYNC": ""]))
        #expect(!WineEnvironment.fastSyncIsOn([:]))
    }

    @Test func theBundledListTurnsItOnOnlyForBuildsThatHaveIt() throws {
        let manifest = try RuntimeManifest.bundled()
        let newest = try #require(manifest.runtimes.last)
        #expect(newest.wineHas("osync"))
        #expect(!manifest.runtimes.dropLast().contains { $0.wineHas("osync") })
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
        #expect(!manifest.runtimes[0].wineHas("osync"))
    }

    @Test func everyTreeOfARuntimeFollowsItsMarker() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "fastsync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plain = Wine(runtimeFolder: folder)
        let dxvk = Wine(root: folder.appending(path: "wine-dxvk", directoryHint: .isDirectory))
        #expect(!plain.supportsFastSync)

        var runtime = try #require(RuntimeManifest.bundled().runtimes.last)
        try JSONEncoder().encode(runtime).write(to: folder.appending(path: RuntimeInstaller.markerName))
        #expect(plain.supportsFastSync && dxvk.supportsFastSync)

        runtime.components[0].features = nil
        try JSONEncoder().encode(runtime).write(to: folder.appending(path: RuntimeInstaller.markerName))
        #expect(!dxvk.supportsFastSync)
    }

    @Test func aPlayerCanTurnItOffForOneGameButNotForAStore() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "fastsync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let runtime = try #require(RuntimeManifest.bundled().runtimes.last)
        try JSONEncoder().encode(runtime).write(to: folder.appending(path: RuntimeInstaller.markerName))
        let wine = Wine(runtimeFolder: folder)

        var game = GameRecord(id: .make(), name: "G", executable: "/g.exe", folder: "/", hasMarker: false,
                              addedAt: Date())
        #expect(WineEnvironment.fastSync(for: game, wine: wine))
        #expect(WineEnvironment.fastSync(for: nil, wine: wine))
        game.fastSync = false
        #expect(!WineEnvironment.fastSync(for: game, wine: wine))
        game.store = .steam
        #expect(WineEnvironment.fastSync(for: game, wine: wine))
        #expect(!WineEnvironment.fastSync(for: nil, wine: Wine(root: URL(filePath: "/nowhere/wine"))))
    }
}
