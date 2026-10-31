@testable import EscAppKit
import Foundation
import Testing

@Suite struct StoreGameStartsTests {
    /// What the client's bottle draws with, and what the game asks for.
    func verdict(settled: Bool = true, age: TimeInterval = 4, running: GraphicsBackend? = .dxvk,
                 wanted: GraphicsBackend? = .dxvk, drawn: StoreClient.Drawn = .init(retina: true, dpi: 192),
                 wants: StoreClient.Drawn = .init(retina: true, dpi: 96)) -> StoreGameStarts.Verdict {
        StoreGameStarts.verdict(settled: settled, age: age, running: running, wanted: wanted,
                                drawn: (drawn, wants))
    }

    @Test func gameWithoutFoundSettingsIsPrepared() {
        // Among Us started from Steam's own window: first installed, and again after "Find Launch Settings Again".
        #expect(verdict(settled: false) == .prepare)
    }

    @Test func gameThatMatchesTheClientIsAdopted() {
        #expect(verdict() == .adopt)
    }

    @Test func otherWineTreeIsPrepared() {
        #expect(verdict(running: .dxvk, wanted: .dxmt) == .prepare)
    }

    @Test func retinaForAGameWithoutHighDPIIsPrepared() {
        // Wine halves the mouse position of a program that doesn't handle high DPI while the client runs in
        // Retina mode: none of Banished's buttons could be clicked.
        #expect(verdict(drawn: .init(retina: true, dpi: 192), wants: .init(retina: false, dpi: 96)) == .prepare)
        // Retina off for a game that handles it only draws softer.
        #expect(verdict(drawn: .init(retina: false, dpi: 96), wants: .init(retina: true, dpi: 96)) == .adopt)
    }

    @Test func smallWindowOfAGameIsPreparedFor() {
        // Steam's client keeps Wine's defaults now, so a game's own small window needs the client restarted to
        // get the system DPI that enlarges it. A bottle that already has that DPI is left alone.
        #expect(verdict(drawn: .init(retina: false, dpi: 96), wants: .init(retina: false, dpi: 192)) == .prepare)
        #expect(verdict(drawn: .init(retina: false, dpi: 192), wants: .init(retina: false, dpi: 192)) == .adopt)
    }

    @Test func unknownBackendDoesNotRestart() {
        #expect(verdict(wanted: nil) == .adopt)
    }

    @Test func gameRunningForAWhileIsNeverClosed() {
        // EscApp opened while the game ran: it is taken over, not ended mid-play.
        #expect(verdict(settled: false, age: 600, running: .dxvk, wanted: .dxmt,
                        wants: .init(retina: false, dpi: 96)) == .adopt)
    }

    @Test func treeBackendComesFromItsMarker() throws {
        let tree = FileManager.default.temporaryDirectory.appending(path: "tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tree) }
        #expect(BackendTree.backend(of: tree) == .wined3d)
        let marker = try JSONEncoder().encode(BackendTree.Marker(backend: .dxmt, files: []))
        try marker.write(to: tree.appending(path: BackendTree.markerName))
        #expect(BackendTree.backend(of: tree) == .dxmt)
    }
}

@Suite struct FrozenWindowTests {
    /// `#expect` can't take a mutating call.
    func look(_ frozen: inout FrozenWindow, blank: Bool, cpu: TimeInterval?, at second: TimeInterval) -> Bool {
        frozen.observe(blank: blank, cpu: cpu, at: second)
    }

    /// Among Us on DXVK: a black window and every thread asleep.
    @Test func blankAndIdleIsFrozen() {
        var frozen = FrozenWindow(holds: 10)
        var caught = false
        for second in stride(from: 0.0, through: 12, by: 2) {
            caught = look(&frozen, blank: true, cpu: 30 + second * 0.01, at: second)
        }
        #expect(caught)
    }

    @Test func blackLoadingScreenThatWorksIsNot() {
        var frozen = FrozenWindow(holds: 10)
        for second in stride(from: 0.0, through: 30, by: 2) {
            #expect(!look(&frozen, blank: true, cpu: second * 0.6, at: second))
        }
    }

    @Test func idleWindowWithAPictureIsNot() {
        // A game's own settings window waits for a click and uses nothing.
        var frozen = FrozenWindow(holds: 10)
        for second in stride(from: 0.0, through: 30, by: 2) {
            #expect(!look(&frozen, blank: false, cpu: 5, at: second))
        }
    }

    @Test func aPictureStartsTheWaitAgain() {
        var frozen = FrozenWindow(holds: 10)
        for second in stride(from: 0.0, through: 8, by: 2) { _ = look(&frozen, blank: true, cpu: 5, at: second) }
        #expect(!look(&frozen, blank: false, cpu: 5, at: 10))
        #expect(!look(&frozen, blank: true, cpu: 5, at: 12))
        #expect(!look(&frozen, blank: true, cpu: 5, at: 20))
        #expect(look(&frozen, blank: true, cpu: 5, at: 22))
    }

    /// Among Us frozen on black, with Steam's overlay notice left in its bottom-right corner.
    @Test func aNoticeInTheCornerIsStillNearlyBlank() {
        let width = 48, height = 36
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 30..<33 {
            for x in 40..<46 { pixels[(y * width + x) * 4] = 200 }
        }
        let share = WindowPicture.flatShare(pixels: pixels, width: width, height: height)
        #expect(!WindowPicture.isBlank(pixels: pixels, width: width, height: height))
        #expect(share >= WindowPicture.nearlyBlankShare)
    }

    @Test func anEndedProcessStartsTheWaitAgain() {
        // A helper of the game ends and takes its CPU seconds with it: the sum drops, which isn't idling.
        var frozen = FrozenWindow(holds: 10)
        var caught: [Bool] = []
        for second in stride(from: 0.0, through: 8, by: 2) {
            caught.append(frozen.observe(blank: true, cpu: 50 + second * 0.01, owners: [1, 2], at: second))
        }
        caught.append(frozen.observe(blank: true, cpu: 20, owners: [1], at: 10))
        caught.append(frozen.observe(blank: true, cpu: 20, owners: [1], at: 18))
        let afterTen = frozen.observe(blank: true, cpu: 20, owners: [1], at: 20)
        #expect(!caught.contains(true))
        #expect(afterTen)
    }

    @Test func unknownCPUNeverFreezes() {
        var frozen = FrozenWindow(holds: 1)
        for second in stride(from: 0.0, through: 10, by: 1) {
            #expect(!look(&frozen, blank: true, cpu: nil, at: second))
        }
    }
}

extension AutoLaunchTests {
    /// Among Us from Steam: DXVK plays the intro, then hangs on a black window; the search goes on to DXMT.
    @Test func storeGameFrozenOnABlankWindowTriesTheNextBackend() async throws {
        var storeGame = game
        storeGame.store = .steam
        storeGame.storeID = "945360"
        try GameLibrary.modify(paths.library) { $0[storeGame.id] = storeGame }
        let starter = try FakeStarter([.dxvk: Script(windowAt: 0.02, exitAt: 5), .dxmt: .works], logs: logs())
        let picture: @Sendable ([Int32]) async -> WindowLook? = { owners in
            WindowLook(window: 1, blank: owners == [100])
        }
        var fast = timing
        fast.lateEvery = 0.005
        fast.lateWatch = 1
        fast.frozenFor = 0.1
        let result = try await AutoLaunch(paths: paths, starter: starter, windows: starter.windows,
                                          measure: { _ in nil }, picture: picture, gpuProcess: { _ in false },
                                          cpu: { _ in 1 }, fullScreen: { _ in false }, timing: fast)
            .play(storeGame, runtime: runtime)
        #expect(starter.started.map(\.0) == [.dxvk, .dxmt])
        #expect(result.attempts.first?.failure == .frozen)
        #expect(result.working == .dxmt)
    }
}

extension AutoLaunchTests {
    /// Among Us on DXVK froze after its intro, before its window had been up the 15 s that make an attempt work.
    @Test func gameFrozenWhileCheckedTriesTheNextBackend() async throws {
        let starter = try FakeStarter([.dxvk: Script(windowAt: 0.02, exitAt: 5), .dxmt: .works], logs: logs())
        let picture: @Sendable ([Int32]) async -> WindowLook? = { owners in
            WindowLook(window: 1, blank: owners == [100])
        }
        var slow = timing
        slow.windowHolds = 2
        slow.pictureEvery = 0.005
        slow.frozenFor = 0.1
        let result = try await AutoLaunch(paths: paths, starter: starter, windows: starter.windows,
                                          measure: { _ in nil }, picture: picture, gpuProcess: { _ in false },
                                          cpu: { _ in 1 }, fullScreen: { _ in false }, timing: slow)
            .play(game, runtime: runtime)
        #expect(starter.started.map(\.0) == [.dxvk, .dxmt])
        #expect(result.attempts.first?.failure == .frozen)
    }
}

@Suite struct WindowGoneJudgeTests {
    /// Among Us crashed with its window gone; Steam's word on the exit code came 45 s later.
    @Test func windowGoneAtTheHoldMarkIsNotWorking() {
        var judge = AttemptJudge(windowTimeout: nil, windowHolds: 15)
        _ = judge.observe(elapsed: 2, window: true, exitCode: nil, idle: false)
        #expect(judge.observe(elapsed: 16, window: false, exitCode: nil, idle: false) == nil)
        #expect(judge.observe(elapsed: 60, window: false, exitCode: 1, idle: false) == .failed(.closed(exitCode: 1)))
    }
}

extension AutoLaunchTests {
    /// No Screen Recording permission: the picture is never seen, and a full-screen window with an idle game is
    /// what tells Among Us's freeze.
    @Test func frozenWithoutSeeingThePicture() async throws {
        let starter = try FakeStarter([.dxvk: Script(windowAt: 0.02, exitAt: 5), .dxmt: .works], logs: logs())
        var slow = timing
        slow.windowHolds = 2
        slow.pictureEvery = 0.005
        slow.frozenFor = 0.1
        let result = try await AutoLaunch(paths: paths, starter: starter, windows: starter.windows,
                                          measure: { _ in nil }, picture: { _ in nil }, gpuProcess: { _ in false },
                                          cpu: { _ in 1 }, fullScreen: { $0 == [100] }, timing: slow)
            .play(game, runtime: runtime)
        #expect(starter.started.map(\.0) == [.dxvk, .dxmt])
        #expect(result.attempts.first?.failure == .frozen)
        #expect(result.working == .dxmt)
    }
}
