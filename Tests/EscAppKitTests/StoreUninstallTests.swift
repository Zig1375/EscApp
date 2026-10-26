@testable import EscAppKit
import Foundation
import Testing

@Suite struct StoreUninstallTests {
    let temp: TempFolder
    let paths: AppPaths

    init() throws {
        temp = try TempFolder()
        paths = AppPaths(root: temp.url.appending(path: "EscApp"), games: temp.url.appending(path: "Games"))
    }

    func record(_ store: Store, id: String, folder: URL) -> GameRecord {
        var game = GameRecord(id: GameID.make(), name: "Banished", executable: folder.appending(path: "b.exe").path,
                              folder: folder.path(percentEncoded: false), hasMarker: false, addedAt: Date())
        game.store = store
        game.storeID = id
        return game
    }

    func make(_ files: [String], under root: URL) throws {
        for file in files {
            let url = root.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    @Test func aSteamGameLeavesWithItsManifest() throws {
        let steamapps = paths.bottle(forGame: Store.steam.bottleID)
            .appending(path: "drive_c/Program Files (x86)/Steam/steamapps", directoryHint: .isDirectory)
        try make(["common/Banished/b.exe", "appmanifest_242920.acf", "appmanifest_70.acf",
                  "workshop/appworkshop_242920.acf"], under: steamapps)
        var trashed: [URL] = []
        try StoreUninstall.remove(record(.steam, id: "242920", folder: steamapps.appending(path: "common/Banished")),
                                  paths: paths) { trashed.append($0); try FileManager.default.removeItem(at: $0) }

        #expect(trashed.map(\.lastPathComponent) == ["Banished", "appmanifest_242920.acf", "appworkshop_242920.acf"])
        let left = try FileManager.default.contentsOfDirectory(atPath: steamapps.path).sorted()
        // Another game's manifest stays.
        #expect(left == ["appmanifest_70.acf", "common", "workshop"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: steamapps.appending(path: "workshop").path).isEmpty)
    }

    @Test func anEpicGameLeavesTheLaunchersLists() throws {
        let data = paths.bottle(forGame: Store.epic.bottleID).appending(path: "drive_c/ProgramData/Epic",
                                                                         directoryHint: .isDirectory)
        let folder = paths.bottle(forGame: Store.epic.bottleID).appending(path: "drive_c/Games/Fall")
        try make(["b.exe"], under: folder)
        let item = #"{"DisplayName": "Fall", "InstallLocation": "C:\\Games\\Fall", "AppName": "Kestrel"}"#
        let other = #"{"DisplayName": "Other", "InstallLocation": "C:\\Games\\Other", "AppName": "Other"}"#
        try make(["EpicGamesLauncher/Data/Manifests/A.item", "EpicGamesLauncher/Data/Manifests/B.item",
                  "UnrealEngineLauncher/LauncherInstalled.dat"], under: data)
        try Data(item.utf8).write(to: data.appending(path: "EpicGamesLauncher/Data/Manifests/A.item"))
        try Data(other.utf8).write(to: data.appending(path: "EpicGamesLauncher/Data/Manifests/B.item"))
        let list = #"{"InstallationList": [{"AppName": "Kestrel"}, {"AppName": "Other"}]}"#
        try Data(list.utf8).write(to: data.appending(path: "UnrealEngineLauncher/LauncherInstalled.dat"))

        try StoreUninstall.remove(record(.epic, id: "ns:item:Kestrel", folder: folder), paths: paths) {
            try FileManager.default.removeItem(at: $0)
        }

        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let manifests = try FileManager.default.contentsOfDirectory(
            atPath: data.appending(path: "EpicGamesLauncher/Data/Manifests").path)
        #expect(manifests == ["B.item"])
        let installed = try String(contentsOf: data.appending(path: "UnrealEngineLauncher/LauncherInstalled.dat"),
                                   encoding: .utf8)
        #expect(!installed.contains("Kestrel") && installed.contains("Other"))
    }

    @Test func steamAndEpicGamesAreRemovedWithoutTheirClient() {
        #expect(StoreUninstall.canRemove(.steam) && StoreUninstall.canRemove(.epic))
    }
}
