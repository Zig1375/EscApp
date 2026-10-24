@testable import EscAppKit
import Foundation
import Testing

/// A bottle as Wine lays it out, enough for reading stores' records: `drive_c` and its `c:` link.
private func makeBottle(in temp: TempFolder, name: String = "Bottle") throws -> URL {
    let bottle = temp.url.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bottle.appending(path: "drive_c"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bottle.appending(path: "dosdevices"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: bottle.appending(path: "dosdevices/c:").path,
                                               withDestinationPath: "../drive_c")
    return bottle
}

@Suite struct ValveKeyValuesTests {
    @Test func readsBlocksValuesAndEscapes() {
        let file = ValveKeyValues.parse(#"""
            // Steam writes a comment now and then
            "AppState"
            {
                "appid"     "400"
                "name"      "Portal \"2\""
                "InstallDir"    "Portal 2"
                "UserConfig" { "language" "english" }
            }
            "path" "C:\\Program Files (x86)\\Steam"
            """#)
        let state = file["appstate"]
        #expect(state?["APPID"]?.string == "400")
        #expect(state?["name"]?.string == #"Portal "2""#)
        #expect(state?["installdir"]?.string == "Portal 2")
        #expect(state?["UserConfig"]?["language"]?.string == "english")
        #expect(file["path"]?.string == #"C:\Program Files (x86)\Steam"#)
        #expect(state?["missing"] == nil)
    }

    @Test func malformedTextGivesWhatWasRead() {
        let file = ValveKeyValues.parse(#""a" "1" "b" { "c" "2""#)
        #expect(file["a"]?.string == "1")
        #expect(file["b"]?["c"]?.string == "2")
    }
}

@Suite struct StoreLibraryTests {
    let temp: TempFolder

    init() throws { temp = try TempFolder() }

    @Test func steamListsOnlyInstalledGamesAcrossLibraryFolders() throws {
        let bottle = try makeBottle(in: temp)
        let steamapps = bottle.appending(path: "drive_c/Program Files (x86)/Steam/steamapps")
        let second = bottle.appending(path: "drive_c/SteamLibrary/steamapps")
        for folder in [steamapps, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try #"""
            "libraryfolders" {
                "0" { "path" "C:\\Program Files (x86)\\Steam" }
                "1" { "path" "C:\\SteamLibrary" }
            }
            """#.write(to: steamapps.appending(path: "libraryfolders.vdf"), atomically: true, encoding: .utf8)
        func manifest(_ id: String, _ name: String, flags: Int) -> String {
            #""AppState" { "appid" "\#(id)" "name" "\#(name)" "installdir" "\#(name)" "StateFlags" "\#(flags)" }"#
        }
        try manifest("400", "Portal 2", flags: 4).write(to: steamapps.appending(path: "appmanifest_400.acf"),
                                                         atomically: true, encoding: .utf8)
        // Downloading for the first time: not installed yet.
        try manifest("620", "Portal", flags: 1026).write(to: steamapps.appending(path: "appmanifest_620.acf"),
                                                          atomically: true, encoding: .utf8)
        // Updating keeps bit 4.
        try manifest("70", "Half-Life", flags: 1030).write(to: second.appending(path: "appmanifest_70.acf"),
                                                            atomically: true, encoding: .utf8)
        try manifest("228980", "Steamworks Common Redistributables", flags: 4)
            .write(to: steamapps.appending(path: "appmanifest_228980.acf"), atomically: true, encoding: .utf8)

        let games = StoreLibrary.steamGames(bottle: bottle).sorted { $0.id < $1.id }
        #expect(games.map(\.id) == ["400", "70"])
        #expect(games[0].folder.lastPathComponent == "Portal 2")
        #expect(games[0].folder.deletingLastPathComponent().lastPathComponent == "common")
        #expect(games[1].folder.path.contains("SteamLibrary/steamapps/common/Half-Life"))
    }

    @Test func epicNamesItsLaunchIDAndProgram() throws {
        let bottle = try makeBottle(in: temp)
        let item = Data(#"""
            {"DisplayName": "Celeste", "InstallLocation": "C:\\Program Files\\Epic Games\\Celeste",
             "LaunchExecutable": "Celeste.exe", "AppName": "Salt", "CatalogNamespace": "ns",
             "CatalogItemId": "item", "bIsIncompleteInstall": false}
            """#.utf8)
        let game = try #require(StoreLibrary.epicGame(item: item, bottle: bottle))
        #expect(game.id == "ns:item:Salt")
        #expect(game.name == "Celeste")
        #expect(game.executable?.lastPathComponent == "Celeste.exe")
        #expect(game.executable?.deletingLastPathComponent().lastPathComponent == "Celeste")
        let incomplete = Data(#"""
            {"DisplayName": "X", "InstallLocation": "C:\\X", "AppName": "X", "bIsIncompleteInstall": true}
            """#.utf8)
        #expect(StoreLibrary.epicGame(item: incomplete, bottle: bottle) == nil)
        // The launch link takes the colons encoded.
        #expect(Store.epic.playArguments(storeID: game.id)
            == ["com.epicgames.launcher://apps/ns%3Aitem%3ASalt?action=launch&silent=true"])
    }

    @Test func gogAndUbisoftComeFromTheRegistry() throws {
        let bottle = try makeBottle(in: temp)
        try FileManager.default.createDirectory(at: bottle.appending(path: "drive_c/Ubi/Far Cry"),
                                                withIntermediateDirectories: true)
        let systemReg = #"""
            WINE REGISTRY Version 2

            [Software\\Wow6432Node\\GOG.com\\Games\\1207658924] 1792800000
            #time=1d
            "exe"="C:\\GOG Games\\Fallout 2\\fallout2.exe"
            "gameName"="Fallout 2"
            "path"="C:\\GOG Games\\Fallout 2"

            [Software\\Wow6432Node\\GOG.com\\Games\\1207658924\\Extra] 1792800000

            [Software\\Wow6432Node\\Ubisoft\\Launcher\\Installs\\85] 1792800000
            "InstallDir"="C:/Ubi/Far Cry/"

            [Software\\Wow6432Node\\Ubisoft\\Launcher\\Installs\\86] 1792800000
            "InstallDir"="C:/Ubi/Removed/"
            """#
        let gog = StoreLibrary.gogGames(systemReg: systemReg, bottle: bottle)
        #expect(gog.map(\.id) == ["1207658924"])
        #expect(gog.first?.name == "Fallout 2")
        #expect(gog.first?.executable?.lastPathComponent == "fallout2.exe")
        let ubisoft = StoreLibrary.ubisoftGames(systemReg: systemReg, bottle: bottle)
        // A game whose folder is gone isn't listed.
        #expect(ubisoft.map(\.id) == ["85"])
        #expect(ubisoft.first?.name == "Far Cry")
    }

    @Test func eaGamesNameTheirContentID() {
        #expect(StoreLibrary.eaContentID("<game><contentIDs><contentID> 1234 </contentID></contentIDs></game>")
            == "1234")
        #expect(StoreLibrary.eaContentID("<game/>") == nil)
    }

    @Test func syncAddsKeepsAndRemovesStoreGames() throws {
        let folder = temp.url.appending(path: "Portal 2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let exe = folder.appending(path: "portal2.exe")
        try FileManager.default.copyItem(at: Probes.url("d3d9-x86"), to: exe)
        let portal = StoreLibrary.Game(store: .steam, id: "400", name: "Portal 2", folder: folder)
        let fromDisk = GameRecord(id: .make(), name: "Diablo II", executable: "/g/d2.exe", folder: "/g",
                                  hasMarker: true, addedAt: Date())
        var library = GameLibrary(games: [fromDisk])

        #expect(StoreLibrary.merge([.steam: [portal]], into: &library, now: Date()))
        let added = try #require(library.games.first { $0.store == .steam })
        #expect(added.storeID == "400")
        // No program named by the store: the one in the folder.
        #expect(URL(filePath: added.executable).resolvingSymlinksInPath() == exe.resolvingSymlinksInPath())
        #expect(added.bottleID == Store.steam.bottleID)

        // Played, then synced again: the same record, its play time kept; nothing changes.
        library.recordPlay(of: added.id, duration: 60, working: .dxvk)
        #expect(!StoreLibrary.merge([.steam: [portal]], into: &library, now: Date()))
        #expect(library[added.id]?.playTime == 60)

        // Uninstalled in Steam: it goes. The game from disk stays.
        #expect(StoreLibrary.merge([.steam: []], into: &library, now: Date()))
        #expect(library.games.map(\.id) == [fromDisk.id])
    }

    @Test func aGameWithoutAnyProgramWaits() {
        let empty = temp.url.appending(path: "Downloading", directoryHint: .isDirectory)
        let game = StoreLibrary.Game(store: .steam, id: "1", name: "Big Game", folder: empty)
        var library = GameLibrary()
        #expect(!StoreLibrary.merge([.steam: [game]], into: &library, now: Date()))
        #expect(library.games.isEmpty)
    }
}

@Suite struct StoreTests {
    @Test func everyStoreHasItsOwnFixedBottle() {
        let ids = Store.allCases.map(\.bottleID)
        #expect(Set(ids).count == Store.allCases.count)
        #expect(Store.steam.bottleID.rawValue == "E5CA5704-0000-4000-8000-000000000001")
        // Valid game ids, so they name a bottle folder like any game's.
        #expect(ids.allSatisfy { GameID(rawValue: $0.rawValue) == $0 })
        #expect(Store.owning(bottle: Store.ubisoft.bottleID) == .ubisoft)
        #expect(Store.owning(bottle: .make()) == nil)
        // Settings files keep the short name.
        #expect(Store.eaApp.rawValue == "ea")
    }

    @Test func steamStartsGamesWithItsWrappedHelperUnchecked() {
        #expect(Store.steam.clientArguments(clientReady: true) == ["-no-cef-sandbox", "-noverifyfiles"])
        #expect(Store.steam.clientArguments(clientReady: false) == ["-no-cef-sandbox"])
        #expect(Store.steam.playArguments(storeID: "400") == ["-silent", "-applaunch", "400"])
        #expect(Store.steam.uninstallArguments(storeID: "400") == ["steam://uninstall/400"])
        #expect(!Store.gog.launchesGames)
    }

    @Test func eaAppIsFoundInItsNewestVersionFolder() throws {
        let temp = try TempFolder()
        let bottle = try makeBottle(in: temp)
        let root = bottle.appending(path: "drive_c/Program Files/Electronic Arts/EA Desktop")
        for version in ["13.9.0.5900", "13.10.1.5940"] {
            let exe = root.appending(path: "\(version)/EA Desktop/EADesktop.exe")
            try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: exe.path, contents: Data())
        }
        // The junction Wine leaves as an empty folder.
        try FileManager.default.createDirectory(at: root.appending(path: "EA Desktop"),
                                                withIntermediateDirectories: true)
        #expect(Store.eaApp.client(in: bottle)?.path.contains("13.10.1.5940") == true)
        #expect(Store.steam.client(in: bottle) == nil)
    }

    @Test func steamsFirstUpdateIsReadFromItsLog() {
        let log = """
            [2026-10-24 04:48:33] Downloaded new manifest: /client/steam_client_win32 version 1769731672
            [2026-10-24 04:48:49] Shutdown
            [2026-10-24 04:48:51] Downloaded new manifest: /steam_client_win64 version 1792618285, installed version 0
            [2026-10-24 04:48:52] Загрузка обновления (13,352 из 239,614 КБ)...
            """
        #expect(!StoreClient.steamUpdateFinished(log: log))
        #expect(StoreClient.steamDownload(in: log)! == (13352, 239_614))
        #expect(StoreClient.steamUpdateFinished(log: log + "\n[2026-10-24 04:49:09] Shutdown"))
        // Later starts check the same manifest and skip it.
        #expect(StoreClient.steamUpdateFinished(log: log + """

            [2026-10-24 04:49:09] Shutdown
            [2026-10-24 04:51:14] Download skipped: /steam_client_win64 version 1792618285, installed version 1792618285
            """))
        #expect(StoreClient.steamDownload(in: "Downloading update (2,031 of 239,614 KB)...")! == (2031, 239_614))
        #expect(StoreClient.steamDownload(in: "nothing") == nil)
    }

    @Test func onlyAWindowsProgramOrPackageRuns() throws {
        let temp = try TempFolder()
        let html = temp.url.appending(path: "setup.exe")
        try Data("<html>Access denied</html>".utf8).write(to: html)
        #expect(!StoreClient.isInstaller(html, package: false))
        #expect(StoreClient.isInstaller(Probes.url("setup-x86"), package: false))
        let package = Probes.folder.deletingLastPathComponent().appending(path: "installers/probe-game.msi")
        #expect(StoreClient.isInstaller(package, package: true))
        #expect(!StoreClient.isInstaller(Probes.url("setup-x86"), package: true))
    }
}

@Suite struct ChromiumHelperTests {
    let temp: TempFolder

    init() throws { temp = try TempFolder() }

    @Test func wrapsTheVendorsHelperOnceAndAgainAfterAnUpdate() throws {
        let wrapper = try #require(ChromiumHelper.wrapper)
        #expect(wrapper.range(of: ChromiumHelper.marker) != nil)
        let folder = temp.url.appending(path: "cef.win64", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let helper = folder.appending(path: "steamwebhelper.exe")
        let real = folder.appending(path: "steamwebhelper_real.exe")
        try Data("vendor 1".utf8).write(to: helper)

        #expect(try ChromiumHelper.wrap(helper, with: wrapper))
        #expect(try Data(contentsOf: helper) == wrapper)
        #expect(try Data(contentsOf: real) == Data("vendor 1".utf8))
        #expect(try !ChromiumHelper.wrap(helper, with: wrapper))

        // Steam's update puts its new helper back: that one becomes the real one.
        try Data("vendor 2".utf8).write(to: helper)
        #expect(try ChromiumHelper.wrap(helper, with: wrapper))
        #expect(try Data(contentsOf: real) == Data("vendor 2".utf8))
        #expect(try Data(contentsOf: helper) == wrapper)
    }

    @Test func aVendorsHelperPutBackIsNoticed() throws {
        let bottle = temp.url.appending(path: "bottle", directoryHint: .isDirectory)
        let helper = bottle.appending(path: "drive_c/Program Files (x86)/Steam/bin/cef/cef.win64/steamwebhelper.exe")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        #expect(!ChromiumHelper.needsWrapping(.steam, in: bottle))
        try Data("vendor".utf8).write(to: helper)
        #expect(ChromiumHelper.needsWrapping(.steam, in: bottle))
        try ChromiumHelper.wrap(.steam, in: bottle)
        #expect(!ChromiumHelper.needsWrapping(.steam, in: bottle))
    }

    @Test func aStarStandsForEachFolder() throws {
        let drive = temp.url.appending(path: "drive_c", directoryHint: .isDirectory)
        for name in ["cef.win7x64", "cef.win64"] {
            let file = drive.appending(path: "Steam/bin/cef/\(name)/steamwebhelper.exe")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: Data())
        }
        let found = ChromiumHelper.expand("Steam/bin/cef/*/steamwebhelper.exe", in: drive)
        #expect(Set(found.map { $0.deletingLastPathComponent().lastPathComponent }) == ["cef.win7x64", "cef.win64"])
        #expect(ChromiumHelper.expand("Steam/bin/missing/*/x.exe", in: drive).isEmpty)
    }
}

@Suite struct WineProcessesTests {
    @Test func tellsAStoreGameFromItsClient() {
        let folder = #"C:\Program Files (x86)\Steam\steamapps\common\Portal 2"#
        let game = #"C:\Program Files (x86)\Steam\steamapps\common\Portal 2\portal2.exe"#
        #expect(WineProcesses.runs(game, from: folder))
        #expect(WineProcesses.runs(#"c:/program files (x86)/steam/steamapps/common/portal 2/bin/x.exe"#, from: folder))
        #expect(!WineProcesses.runs(#"C:\Program Files (x86)\Steam\steam.exe"#, from: folder))
        // A folder whose name starts the same isn't inside it.
        let mod = #"C:\Program Files (x86)\Steam\steamapps\common\Portal 2 Mods\m.exe"#
        #expect(!WineProcesses.runs(mod, from: folder))
    }

    @Test func findsTheWineTreeOfALoader() {
        #expect(WineProcesses.wineTree(of: "/R/w/wine-dxvk/bin/wine-preloader")?.path == "/R/w/wine-dxvk")
        #expect(WineProcesses.wineTree(of: "/R/wine/lib/wine/x86_64-unix/wine")?.path == "/R/wine")
        #expect(WineProcesses.wineTree(of: "/usr/sbin/nothing") == nil)
    }

    @Test func readsTheArgumentsBeforeTheEnvironment() {
        var bytes: [UInt8] = [2, 0, 0, 0]
        for part in ["/w/bin/wine-preloader", "", #"C:\Steam\steam.exe"#, "-silent", "WINEPREFIX=/b"] {
            bytes += Array(part.utf8) + [0]
        }
        let parsed = GameWindows.parseProcArguments(bytes)
        #expect(parsed.arguments == [#"C:\Steam\steam.exe"#, "-silent"])
        #expect(parsed.environment == ["WINEPREFIX": "/b"])
    }

    @Test func aStoreGamesFolderAsWindowsSeesIt() throws {
        let temp = try TempFolder()
        let bottle = try makeBottle(in: temp)
        let game = bottle.appending(path: "drive_c/Program Files (x86)/Steam/steamapps/common/Portal 2")
        #expect(WindowsPath.windowsPath(of: game, inBottle: bottle)
            == #"C:\Program Files (x86)\Steam\steamapps\common\Portal 2"#)
        #expect(WindowsPath.windowsPath(of: URL(filePath: "/Volumes/Games/Portal 2"), inBottle: bottle)
            == #"Z:\Volumes\Games\Portal 2"#)
    }

    @Test func aGameNeedingSteamIsRecognised() {
        let diagnosis = LogDiagnosis(log: """
            [S_API FAIL] SteamAPI_Init() failed; SteamAPI_IsSteamRunning() failed.
            """)
        #expect(diagnosis.problem == .needsSteam)
        #expect(!diagnosis.retryHelps)
    }
}

@Suite struct EpicUpdateTests {
    @Test func theInstallingUpdatesWindowIsToldFromTheService() {
        let program = "C:/Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesUpdater.exe"
        func process(_ arguments: [String]) -> WineProcesses.Process {
            .init(pid: 1, executable: "/w/bin/wine", program: program, arguments: arguments)
        }
        #expect(StoreClient.isWaitingUpdater(process(["start", "-epicenv=Prod"])))
        #expect(!StoreClient.isWaitingUpdater(process(["queryinstallation", "strict"])))
        #expect(!StoreClient.isWaitingUpdater(process([])))
        var launcher = process(["start"])
        launcher.program = #"C:\Program Files\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe"#
        #expect(!StoreClient.isWaitingUpdater(launcher))
    }

    @Test func aDownloadedUpdateIsOneWithFilesInItsStage() throws {
        let bottle = FileManager.default.temporaryDirectory.appending(path: "epic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bottle) }
        let stage = StoreClient.epicUpdateStage(bottle)
        #expect(!StoreClient.epicHasStagedUpdate(bottle))
        // Installing it leaves the empty folders behind.
        try FileManager.default.createDirectory(at: stage.appending(path: "Portal/Binaries"),
                                                withIntermediateDirectories: true)
        #expect(!StoreClient.epicHasStagedUpdate(bottle))
        try Data("x".utf8).write(to: stage.appending(path: "Portal/Binaries/EpicGamesLauncher.exe"))
        #expect(StoreClient.epicHasStagedUpdate(bottle))
    }

    @Test func theLauncherDrawsWithOpenGL() {
        #expect(Store.epic.clientArguments(clientReady: true).contains("-opengl"))
    }
}

extension EpicUpdateTests {
    @Test func aLauncherOnItsLogoIsToldFromOneShowingItsPages() {
        let stuck = """
            [2026.10.24-12.26.57:534][101]LogInit: AllCheckComplete SelfUpdate=1 SignedIn=0 RequiresRestart=0
            [2026.10.24-12.27.25:564][634]LogPortal: Warning: Memory pressure detected: 317.7% of commit limit used
            """
        let shown = stuck + "\n[2026.10.24-12.06.15:873][367]LogWebView:   WARN  [Statsig] The user does not have"
        #expect(!StoreClient.showsPages(Data(stuck.utf8)))
        #expect(StoreClient.showsPages(Data(shown.utf8)))
    }
}
