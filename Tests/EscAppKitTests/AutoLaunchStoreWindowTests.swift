@testable import EscAppKit
import Foundation
import Testing

/// A store game's own window timeout (`Timing.storeWindowTimeout`): the client EscApp starts it through may sit at
/// its sign-in far longer than a game EscApp starts itself, so only a store game waits that long (`AutoLaunch`).
extension AutoLaunchTests {
    @Test func aStoreGameIsWaitedForUpToItsOwnTimeout() async throws {
        var steamGame = game
        steamGame.store = .steam
        steamGame.storeID = "400"
        var storeTiming = timing
        storeTiming.storeWindowTimeout = 0.5
        // Its window comes at 0.4 s, well after `firstWindowTimeout` (0.2 s): with that one the game would have
        // been given up on as showing nothing and sent to DXMT.
        let starter = try FakeStarter([.dxvk: Script(windowAt: 0.4, exitAt: 1), .dxmt: .works], logs: logs())
        let result = try await AutoLaunch(paths: paths, starter: starter, windows: starter.windows,
                                          measure: { _ in nil }, picture: { _ in nil }, cpu: { _ in nil },
                                          fullScreen: { _ in false }, timing: storeTiming)
            .play(steamGame, runtime: runtime)
        #expect(starter.started.map(\.0) == [.dxvk])
        #expect(result.working == .dxvk)
    }

    @Test func aStoreGameThatMissesItsOwnTimeoutTriesTheNextBackend() async throws {
        var steamGame = game
        steamGame.store = .steam
        steamGame.storeID = "400"
        var storeTiming = timing
        storeTiming.storeWindowTimeout = 0.4
        // Its window never comes inside the store's timeout: the attempt is given up on as showing nothing, rather
        // than left waiting until the game itself exits.
        let starter = try FakeStarter([.dxvk: Script(windowAt: 0.8, exitAt: 5), .dxmt: .works], logs: logs())
        let result = try await AutoLaunch(paths: paths, starter: starter, windows: starter.windows,
                                          measure: { _ in nil }, picture: { _ in nil }, cpu: { _ in nil },
                                          fullScreen: { _ in false }, timing: storeTiming)
            .play(steamGame, runtime: runtime)
        #expect(starter.started.map(\.0) == [.dxvk, .dxmt])
        #expect(result.attempts.first?.failure == .noWindow)
        #expect(result.working == .dxmt)
    }
}
