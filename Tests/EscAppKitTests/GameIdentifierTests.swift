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
