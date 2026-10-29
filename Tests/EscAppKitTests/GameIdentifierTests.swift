@testable import EscAppKit
import Foundation
import Testing

@Suite struct GameIdentifierTests {
    let temp: TempFolder
    let home: URL
    let paths: AppPaths
    let identifier: GameIdentifier

    init() throws {
        temp = try TempFolder()
        // Resolved, because /var is a link to /private/var and paths are compared resolved.
        home = temp.url.resolvingSymlinksInPath().appending(path: "home", directoryHint: .isDirectory)
        paths = AppPaths(root: home.appending(path: "Library/EscApp"), games: home.appending(path: "Games"))
        identifier = GameIdentifier(paths: paths, home: home)
    }

    @discardableResult
    func makeExe(_ path: String, contents: String = "MZ game") throws -> URL {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func library() throws -> GameLibrary { try GameLibrary.load(from: paths.library) }

    @Test func aNewGameGetsAMarkerNextToTheExe() throws {
        let exe = try makeExe("Games/Heroes3/Heroes3.exe")
        let result = try identifier.identify(executable: exe)
        #expect(result.method == .new)
        #expect(result.record.name == "Heroes3")
        #expect(result.record.hasMarker)
        #expect(result.record.fingerprint == nil)
        #expect(identifier.readMarker(in: exe.deletingLastPathComponent()) == result.record.id)
        #expect(try library().games == [result.record])
    }

    /// The default from Settings goes to games added after it; a game already known keeps its own setting.
    @Test func aNewGameGetsTheRetinaDefault() throws {
        let heroes = try makeExe("Games/Heroes3/Heroes3.exe")
        #expect(try identifier.identify(executable: heroes).record.retina == nil)
        try SharedSettings(newGameRetina: .off).save(to: paths.settings)
        #expect(try identifier.identify(executable: heroes).record.retina == nil)
        let fallout = try makeExe("Games/Fallout2/fallout2.exe")
        #expect(try identifier.identify(executable: fallout).record.retina == .off)
        try SharedSettings(newGameRetina: .auto).save(to: paths.settings)
        #expect(try identifier.identify(executable: makeExe("Games/Diablo/diablo.exe")).record.retina == nil)
    }

    @Test func theSameGameIsFoundAgainAndFromAnotherExeInItsFolders() throws {
        let launcher = try makeExe("Games/Witcher/launcher.exe")
        let first = try identifier.identify(executable: launcher)
        let game = try makeExe("Games/Witcher/bin/x64/witcher.exe")

        let again = try identifier.identify(executable: game)
        #expect(again.method == .marker)
        #expect(again.record.id == first.record.id)
        #expect(again.record.executable.hasSuffix("bin/x64/witcher.exe"))
        #expect(try library().games.count == 1)
    }

    @Test func theMarkerGoesToTheGameFolderNotItsBinaryFolder() throws {
        let game = try makeExe("Games/Witcher3/bin/x64/witcher3.exe")
        let result = try identifier.identify(executable: game)
        #expect(result.record.name == "Witcher3")
        #expect(identifier.readMarker(in: home.appending(path: "Games/Witcher3")) == result.record.id)
        let launcher = try makeExe("Games/Witcher3/REDprelauncher.exe")
        #expect(try identifier.identify(executable: launcher).record.id == result.record.id)
    }

    @Test func unrealGamesUseTheFolderWithEngine() throws {
        let game = try makeExe("Games/Satisfactory/FactoryGame/Binaries/Win64/FactoryGame-Win64-Shipping.exe")
        try FileManager.default.createDirectory(at: home.appending(path: "Games/Satisfactory/Engine"),
                                                withIntermediateDirectories: true)
        let result = try identifier.identify(executable: game)
        #expect(result.record.name == "Satisfactory")
        let launcher = try makeExe("Games/Satisfactory/FactoryGame.exe")
        #expect(try identifier.identify(executable: launcher).record.id == result.record.id)
    }

    @Test func aMovedFolderKeepsItsIdentity() throws {
        let exe = try makeExe("Games/Fallout2/fallout2.exe")
        let first = try identifier.identify(executable: exe)
        let moved = home.appending(path: "External/Fallout2")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: exe.deletingLastPathComponent(), to: moved)

        let again = try identifier.identify(executable: moved.appending(path: "fallout2.exe"))
        #expect(again.record.id == first.record.id)
        #expect(again.record.folder.hasSuffix("External/Fallout2/"))
    }

    @Test func aCopiedFolderBecomesItsOwnGame() throws {
        let exe = try makeExe("Games/Skyrim/skyrim.exe")
        let original = try identifier.identify(executable: exe)
        let copy = home.appending(path: "Games/Skyrim Mods")
        try FileManager.default.copyItem(at: exe.deletingLastPathComponent(), to: copy)

        let result = try identifier.identify(executable: copy.appending(path: "skyrim.exe"))
        #expect(result.method == .copiedFolder)
        #expect(result.record.id != original.record.id)
        #expect(identifier.readMarker(in: copy) == result.record.id)
        #expect(identifier.readMarker(in: exe.deletingLastPathComponent()) == original.record.id)
        #expect(try library().games.count == 2)
    }

    @Test func noMarkerInSharedFolders() throws {
        let exe = try makeExe("Downloads/setup_game.exe")
        let result = try identifier.identify(executable: exe)
        #expect(!result.record.hasMarker)
        #expect(result.record.fingerprint == nil)
        #expect(result.record.name == "setup_game")
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "Downloads/.escapp").path))
    }

    @Test func searchStopsAtSharedFolders() throws {
        // A stray .escapp in ~/Games must not swallow every game below it.
        try Data(#"{"format":1,"id":"\#(GameID.make())"}"#.utf8).write(to: try makeExe("Games/.escapp").absoluteURL)
        let exe = try makeExe("Games/Diablo/diablo.exe")
        #expect(try identifier.identify(executable: exe).method == .new)
    }

    @Test func onlyTheMarkerFindsAGame() throws {
        // A game EscApp couldn't mark (read-only folder) isn't found again by its path or its exe: the same exe
        // opened again is a new game.
        let exe = try makeExe("Discs/Heroes/heroes.exe")
        let folder = exe.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let first = try identifier.identify(executable: exe)
        #expect(!first.record.hasMarker)
        let again = try identifier.identify(executable: exe)
        #expect(again.method == .new)
        #expect(again.record.id != first.record.id)
    }

    @Test func removingFromAppKeepsTheGameButForgetsIt() throws {
        let exe = try makeExe("Games/Heroes3/Heroes3.exe")
        let game = try identifier.identify(executable: exe).record
        let bottle = paths.bottle(forGame: game.id)
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)

        try GameRemover.removeFromApp(game.id, paths: paths)
        #expect(try library().games.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bottle.path))
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "Games/Heroes3/.escapp").path))
        #expect(FileManager.default.fileExists(atPath: exe.path))
        #expect(try identifier.identify(executable: exe).method == .new)
    }

    @Test func aForeignMarkerKeepsItsID() throws {
        let id = GameID.make()
        let exe = try makeExe("Games/FromOtherMac/game.exe")
        try identifier.writeMarker(id, in: exe.deletingLastPathComponent())
        let result = try identifier.identify(executable: exe)
        #expect(result.record.id == id)
        #expect(try library()[id] != nil)
    }

    // MARK: Store games

    func storeRecord(_ store: Store, id: String, folder: String, exe: String) -> GameRecord {
        var record = GameRecord(id: .make(), name: "Among Us", executable: exe, folder: folder, hasMarker: false,
                                addedAt: Date(timeIntervalSince1970: 0))
        record.store = store
        record.storeID = id
        return record
    }

    @Test func aStoreGameIsFoundByItsProgramOrFolder() {
        let common = "/B/drive_c/Program Files (x86)/Steam/steamapps/common"
        let amongUs = storeRecord(.steam, id: "945360", folder: "\(common)/Among Us",
                                  exe: "\(common)/Among Us/Among Us.exe")
        let own = GameRecord(id: .make(), name: "Heroes", executable: "/Games/Heroes/h3.exe", folder: "/Games/Heroes",
                             hasMarker: true, addedAt: Date(timeIntervalSince1970: 0))
        let games = [own, amongUs]
        #expect(GameIdentifier.storeGame(at: "\(common)/Among Us/Among Us.exe", in: games) == amongUs)
        #expect(GameIdentifier.storeGame(at: "\(common)/among us/AMONG US.EXE", in: games) == amongUs)
        #expect(GameIdentifier.storeGame(at: "\(common)/Among Us/Tools/crash.exe", in: games) == amongUs)
        // A folder whose name starts like the game's isn't inside it; the player's own games aren't store games.
        #expect(GameIdentifier.storeGame(at: "\(common)/Among Us 2/game.exe", in: games) == nil)
        #expect(GameIdentifier.storeGame(at: "/Games/Heroes/h3.exe", in: games) == nil)
    }

    @Test func theDeepestStoreFolderWins() {
        let outer = storeRecord(.epic, id: "a", folder: "/B/Epic/Game", exe: "/B/Epic/Game/game.exe")
        let inner = storeRecord(.epic, id: "b", folder: "/B/Epic/Game/DLC", exe: "/B/Epic/Game/DLC/dlc.exe")
        #expect(GameIdentifier.storeGame(at: "/B/Epic/Game/DLC/bin/x.exe", in: [inner, outer]) == inner)
        #expect(GameIdentifier.storeGame(at: "/B/Epic/Game/DLC/bin/x.exe", in: [outer, inner]) == inner)
    }

    @Test func anExeInAStoreBottleNamesItsStore() {
        let bottle: (Store) -> String = { "/Bottles/\($0.bottleID.rawValue)" }
        let steam = bottle(.steam)
        #expect(GameIdentifier.storeBottle(containing: "\(steam)/drive_c/x/game.exe", bottle: bottle) == .steam)
        #expect(GameIdentifier.storeBottle(containing: "\(bottle(.epic))/drive_c/g.exe", bottle: bottle) == .epic)
        #expect(GameIdentifier.storeBottle(containing: "/Bottles/\(GameID.make().rawValue)/g.exe",
                                           bottle: bottle) == nil)
    }

    /// Running Among Us's exe from Steam's folder made a second record and wrote `.escapp` into Steam's folder.
    @Test func aStoreGameKeepsItsRecordAndGetsNoMarker() throws {
        let folder = paths.bottle(forGame: Store.steam.bottleID).appending(
            path: "drive_c/Program Files (x86)/Steam/steamapps/common/Among Us", directoryHint: .isDirectory)
        let exe = folder.appending(path: "Among Us.exe")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: exe)
        // A stray marker left there by an earlier version is ignored.
        try identifier.writeMarker(.make(), in: folder)
        let record = storeRecord(.steam, id: "945360", folder: folder.path(percentEncoded: false),
                                 exe: exe.path(percentEncoded: false))
        try GameLibrary(games: [record]).save(to: paths.library)

        let result = try identifier.identify(executable: exe)
        #expect(result.method == .store)
        #expect(result.record == record)
        #expect(try library().games == [record])

        let marker = folder.appending(path: GameIdentifier.markerName)
        try FileManager.default.removeItem(at: marker)
        let other = folder.deletingLastPathComponent().appending(path: "Unknown/game.exe")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: other)
        #expect(throws: GameIdentifier.IdentifyError.self) { try identifier.identify(executable: other) }
        #expect(try library().games == [record])
        #expect(!FileManager.default.fileExists(atPath: other.deletingLastPathComponent()
                .appending(path: GameIdentifier.markerName).path))
    }
}

@Suite struct PlayRecordTests {
    @Test func aFailedRunKeepsTheRememberedBackend() {
        let id = GameID.make()
        var library = GameLibrary(games: [GameRecord(id: id, name: "G", executable: "/g.exe", folder: "/",
                                                     hasMarker: true, addedAt: Date())])
        library.recordPlay(of: id, duration: 19, working: nil)
        #expect(library[id]?.backend == nil)
        #expect(library[id]?.playTime == 19)

        library.recordPlay(of: id, duration: 15, working: .dxmt)
        library.recordPlay(of: id, duration: 4, working: nil)
        #expect(library[id]?.backend == .dxmt)
        #expect(library[id]?.playTime == 38)
        #expect(library[id]?.launches == 3)
    }
}

@Suite struct LaunchHistoryTests {
    @Test func readsTheMarkerLines() {
        let head = """
            [EscApp] Launch 2026-10-23T19:40:00Z
            [EscApp] Game Probe (X)
            [EscApp] Backend dxmt
            err:something from the game
            """
        let run = LaunchHistory.parse(head: head, tail: "noise\n[EscApp] Exit 0 after 17 s, bottle idle after 21 s\n",
                                      log: URL(filePath: "/l.log"))
        #expect(run?.backend == .dxmt)
        #expect(run?.exitCode == 0)
        #expect(run?.processSeconds == 17)
        #expect(run?.sessionSeconds == 21)
        #expect(run?.worked == true)
        #expect(run?.startedAt == ISO8601DateFormatter().date(from: "2026-10-23T19:40:00Z"))
    }

    @Test func aRunWithoutExitLineIsUnfinished() {
        let run = LaunchHistory.parse(head: "[EscApp] Launch 2026-10-23T19:40:00Z\n[EscApp] Backend dxvk\n", tail: "",
                                      log: URL(filePath: "/l.log"))
        #expect(run?.exitCode == nil)
        #expect(run?.worked == nil)
    }

    @Test func aCrashIsNotWorking() {
        let run = LaunchHistory.parse(head: "[EscApp] Launch 2026-10-23T19:40:00Z\n",
                                      tail: "[EscApp] Exit 53 after 3 s, bottle idle after 12 s",
                                      log: URL(filePath: "/l.log"))
        #expect(run?.worked == false)
    }
}
