@testable import EscAppKit
import Foundation
import Testing

@Suite struct StoreSyncTests {
    let temp: TempFolder

    init() throws { temp = try TempFolder() }

    @Test func steamGameStaysWhileItsManifestIsBeingRewritten() throws {
        let steamapps = temp.url.appending(path: "steamapps", directoryHint: .isDirectory)
        let folder = steamapps.appending(path: "common/Banished", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Probes.url("d3d9-x86"), to: folder.appending(path: "Banished.exe"))
        let manifest = steamapps.appending(path: "appmanifest_242920.acf")
        try Data("\"AppState\" {".utf8).write(to: manifest)
        let banished = StoreLibrary.Game(store: .steam, id: "242920", name: "Banished", folder: folder)
        var library = GameLibrary()
        #expect(StoreLibrary.merge([.steam: [banished]], into: &library, now: Date()))
        let id = try #require(library.games.first?.id)

        // Steam is halfway through writing the manifest: the scan can't read it, the game keeps its record.
        #expect(!StoreLibrary.merge([.steam: []], into: &library, now: Date()))
        #expect(library.games.map(\.id) == [id])

        // Uninstalled: the manifest goes, and so does the game.
        try FileManager.default.removeItem(at: manifest)
        #expect(StoreLibrary.merge([.steam: []], into: &library, now: Date()))
        #expect(library.games.isEmpty)
    }

    @Test func aNewStoreGameGetsTheRetinaDefault() throws {
        let folder = temp.url.appending(path: "common/Banished", directoryHint: .isDirectory)
        let banished = StoreLibrary.Game(store: .steam, id: "242920", name: "Banished", folder: folder,
                                         executable: folder.appending(path: "Banished.exe"))
        var library = GameLibrary()
        #expect(StoreLibrary.merge([.steam: [banished]], into: &library, now: Date(), retina: .off))
        #expect(library.games.first?.retina == .off)
    }
}
