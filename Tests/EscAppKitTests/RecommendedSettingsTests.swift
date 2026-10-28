@testable import EscAppKit
import Foundation
import Synchronization
import Testing

/// Settings that travel with the game's folder in `.escapp`: tried first, kept when they work, and only a
/// first guess when they don't.
extension AutoLaunchTests {
    var folder: URL { URL(filePath: game.folder, directoryHint: .isDirectory) }

    /// The game's `.escapp` as it came from another Mac.
    func recommend(_ settings: RecommendedSettings) throws {
        try GameIdentifier.write(GameIdentifier.Marker(id: game.id, recommended: settings), in: folder)
    }

    func markerSettings() -> RecommendedSettings? { GameIdentifier.marker(in: folder)?.recommended }

    @Test func settingsFromTheFolderAreTriedFirstAndKept() async throws {
        try recommend(RecommendedSettings(backend: "wined3d", windows: "winxp"))
        let starter = try FakeStarter([.wined3d: .works, .dxvk: .works], logs: logs())
        let result = try await play(starter)
        #expect(starter.started.map(\.0) == [.wined3d])
        #expect(starter.startedGames.first?.windowsVersion == .windowsXP)
        #expect(result.working == .wined3d)
        let record = try #require(try GameLibrary.load(from: paths.library)[game.id])
        #expect(record.backend == .wined3d)
        #expect(record.windowsVersion == .windowsXP)
    }

    @Test func settingsFromTheFolderThatFailLeadToTheUsualSearch() async throws {
        try recommend(RecommendedSettings(backend: "wined3d", windows: "winxp", chromium: "noGPU"))
        let starter = try FakeStarter([.wined3d: .crashes(), .dxvk: .works], logs: logs())
        let result = try await play(starter)
        #expect(starter.started.map(\.0) == [.wined3d, .dxvk])
        // The next attempts start as a first launch would, without the folder's Windows or Chromium drawing.
        #expect(starter.startedGames.last?.windowsVersion == .default)
        #expect(starter.startedGames.last?.chromium == nil)
        #expect(result.working == .dxvk)
        // What works here replaces them, for whoever gets the folder next.
        #expect(markerSettings() == RecommendedSettings(backend: "dxvk", windows: WindowsVersion.default.wineValue))
    }

    @Test func whatWorksIsWrittenToTheFolder() async throws {
        let starter = try FakeStarter([.dxvk: .crashes(), .dxmt: .works], logs: logs())
        _ = try await play(starter)
        #expect(markerSettings()?.graphicsBackend == .dxmt)
        // The game is still found by the same file.
        #expect(GameIdentifier(paths: paths).readMarker(in: folder) == game.id)
    }

    @Test mutating func aBackendThatWorkedHereComesBeforeTheFolders() async throws {
        try recommend(RecommendedSettings(backend: "wined3d"))
        try GameLibrary.modify(paths.library) { $0[game.id]?.backend = .dxmt }
        game.backend = .dxmt
        let starter = try FakeStarter([.dxmt: .works, .wined3d: .works], logs: logs())
        _ = try await play(starter)
        #expect(starter.started.map(\.0) == [.dxmt])
    }

    @Test func unknownValuesInTheFolderAreIgnored() async throws {
        try recommend(RecommendedSettings(backend: "glide", windows: "win95"))
        #expect(GameIdentifier.recommended(for: game) == nil)
        let starter = try FakeStarter([.dxvk: .works], logs: logs())
        _ = try await play(starter)
        #expect(starter.started.map(\.0) == [.dxvk])
    }

    @Test func aStoreGameIgnoresTheFolder() throws {
        try recommend(RecommendedSettings(backend: "wined3d"))
        var stored = game
        stored.store = .steam
        #expect(GameIdentifier.recommended(for: stored) == nil)
        #expect(GameIdentifier.recommended(for: game)?.graphicsBackend == .wined3d)
    }
}

@Suite struct RecommendedSettingsTests {
    @Test func aMarkerWithoutSettingsStillReadsAndACopyKeepsThem() throws {
        let temp = try TempFolder()
        let home = temp.url.resolvingSymlinksInPath().appending(path: "home", directoryHint: .isDirectory)
        let paths = AppPaths(root: home.appending(path: "Library/EscApp"), games: home.appending(path: "Games"))
        let identifier = GameIdentifier(paths: paths, home: home)
        let exe = home.appending(path: "Games/Doom/doom.exe")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: exe)
        let original = try identifier.identify(executable: exe).record
        // What earlier versions wrote.
        let marker = exe.deletingLastPathComponent().appending(path: GameIdentifier.markerName)
        #expect(try String(contentsOf: marker, encoding: .utf8).contains("recommended") == false)

        GameIdentifier.recommend(RecommendedSettings(backend: .wined3d, windows: .windows7, chromium: nil),
                                 for: original)
        let copy = home.appending(path: "Games/Doom Mods")
        try FileManager.default.copyItem(at: exe.deletingLastPathComponent(), to: copy)
        let copied = try identifier.identify(executable: copy.appending(path: "doom.exe")).record
        #expect(copied.id != original.id)
        #expect(GameIdentifier.recommended(for: copied)?.graphicsBackend == .wined3d)
        #expect(GameIdentifier.recommended(for: copied)?.windowsVersion == .windows7)

        GameIdentifier.recommend(nil, for: original)
        #expect(GameIdentifier.recommended(for: original) == nil)
        #expect(identifier.readMarker(in: exe.deletingLastPathComponent()) == original.id)
    }
}
