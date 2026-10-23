@testable import ExePortKit
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
        paths = AppPaths(root: home.appending(path: "Library/ExePort"), games: home.appending(path: "Games"))
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
        #expect(result.record.fingerprint != nil)
        #expect(result.record.name == "setup_game")
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "Downloads/.exeport").path))
        // Found again by path.
        #expect(try identifier.identify(executable: exe).method == .lastPath)
    }

    @Test func searchStopsAtSharedFolders() throws {
        // A stray .exeport in ~/Games must not swallow every game below it.
        try Data(#"{"format":1,"id":"\#(GameID.make())"}"#.utf8).write(to: try makeExe("Games/.exeport").absoluteURL)
        let exe = try makeExe("Games/Diablo/diablo.exe")
        #expect(try identifier.identify(executable: exe).method == .new)
    }

    @Test func readOnlyFolderFallsBackToFingerprint() throws {
        let exe = try makeExe("Discs/Heroes/heroes.exe")
        let folder = exe.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        let first = try identifier.identify(executable: exe)
        #expect(!first.record.hasMarker)

        // The same disc mounted somewhere else: found by fingerprint.
        let elsewhere = try makeExe("Discs2/Heroes/heroes.exe")
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: elsewhere.deletingLastPathComponent().path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: elsewhere.deletingLastPathComponent().path)
        }
        let again = try identifier.identify(executable: elsewhere)
        #expect(again.method == .fingerprint)
        #expect(again.record.id == first.record.id)
    }

    @Test func identicalExesInDifferentGamesAreDifferentGames() throws {
        // Two Unity games: same player exe, different data next to it, both read-only.
        let first = try makeExe("RO1/GameA/game.exe", contents: "UnityPlayer")
        try Data("a".utf8).write(to: home.appending(path: "RO1/GameA/GameA_Data"))
        let second = try makeExe("RO2/GameB/game.exe", contents: "UnityPlayer")
        try Data("bb".utf8).write(to: home.appending(path: "RO2/GameB/GameB_Data"))
        #expect(try GameIdentifier.fingerprint(of: first) != GameIdentifier.fingerprint(of: second))
    }

    @Test func removingFromAppKeepsTheGameButForgetsIt() throws {
        let exe = try makeExe("Games/Heroes3/Heroes3.exe")
        let game = try identifier.identify(executable: exe).record
        let bottle = paths.bottle(forGame: game.id)
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)

        try GameRemover.removeFromApp(game.id, paths: paths)
        #expect(try library().games.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bottle.path))
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "Games/Heroes3/.exeport").path))
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
    func outcome(exit: Int32, process: TimeInterval, total: TimeInterval) -> GameLauncher.Outcome {
        GameLauncher.Outcome(exitCode: exit, duration: total, processDuration: process, backend: .dxmt,
                             log: URL(filePath: "/tmp/x.log"))
    }

    @Test func aCrashAtStartIsNotRemembered() {
        let id = GameID.make()
        var library = GameLibrary(games: [GameRecord(id: id, name: "G", executable: "/g.exe", folder: "/",
                                                     hasMarker: true, addedAt: Date())])
        // Wine's server lingers ~10 s, so the whole session looks long even when the game died at once.
        library.recordPlay(of: id, outcome: outcome(exit: 53, process: 3, total: 19))
        #expect(library[id]?.backend == nil)
        #expect(library[id]?.playTime == 19)

        library.recordPlay(of: id, outcome: outcome(exit: 0, process: 5, total: 15))
        #expect(library[id]?.backend == .dxmt)
        #expect(library[id]?.playTime == 34)
    }
}

@Suite struct LaunchHistoryTests {
    @Test func readsTheMarkerLines() {
        let head = """
            [ExePort] Launch 2026-10-23T19:40:00Z
            [ExePort] Game Probe (X)
            [ExePort] Backend dxmt
            err:something from the game
            """
        let run = LaunchHistory.parse(head: head, tail: "noise\n[ExePort] Exit 0 after 17 s, bottle idle after 21 s\n",
                                      log: URL(filePath: "/l.log"))
        #expect(run?.backend == .dxmt)
        #expect(run?.exitCode == 0)
        #expect(run?.processSeconds == 17)
        #expect(run?.sessionSeconds == 21)
        #expect(run?.worked == true)
        #expect(run?.startedAt == ISO8601DateFormatter().date(from: "2026-10-23T19:40:00Z"))
    }

    @Test func aRunWithoutExitLineIsUnfinished() {
        let run = LaunchHistory.parse(head: "[ExePort] Launch 2026-10-23T19:40:00Z\n[ExePort] Backend dxvk\n", tail: "",
                                      log: URL(filePath: "/l.log"))
        #expect(run?.exitCode == nil)
        #expect(run?.worked == nil)
    }

    @Test func aCrashIsNotWorking() {
        let run = LaunchHistory.parse(head: "[ExePort] Launch 2026-10-23T19:40:00Z\n",
                                      tail: "[ExePort] Exit 53 after 3 s, bottle idle after 12 s",
                                      log: URL(filePath: "/l.log"))
        #expect(run?.worked == false)
    }
}
