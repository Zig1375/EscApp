@testable import EscAppKit
import Foundation
import Testing

extension AutoLaunchTests.Script {
    /// Shows its window and the player quits before the window check is through; its log has an error that
    /// isn't the game's fault.
    static let quitEarly = Self(windowAt: 0.0, exitAt: 0.6, log: #"""
        err:module:import_dll Library binkw32.dll (which is needed by L"Z:\\g\\game.exe") not found
        """#)
}

extension AutoLaunchTests {
    @Test func aGameQuitCleanlyAfterItsWindowIsNoFailure() async throws {
        // Banished, closed by the player after 16 s: it was reported as not started, with an SDL2.dll that Steam's
        // own gldriverquery.exe had missed.
        // A longer check than the other tests, so the window is surely seen however busy the machine is.
        let slow = AutoLaunch.Timing(poll: .milliseconds(5), windowHolds: 2, firstWindowTimeout: 3,
                                     handOverAfter: 0.15)
        let starter = try FakeStarter([.dxvk: .quitEarly], logs: logs())
        let result = try await AutoLaunch(paths: paths, starter: starter, windows: starter.windows,
                                          measure: { _ in Self.window }, timing: slow)
            .play(game, runtime: runtime)
        #expect(result.attempts.count == 1)
        #expect(result.attempts.first?.failure == nil)
    }
}
