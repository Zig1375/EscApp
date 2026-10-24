@testable import EscAppKit
import Foundation
import Testing

@Suite struct SteamGameLogTests {
    // Banished's first launch from Steam, as Steam logged it: the first process ends with -1 and Steam starts
    // the game again.
    let restart = """
        [2026-10-24 21:19:01] AppID 242920 adding PID 2000 as a tracked process ""C:\\Steam\\Banished.exe""
        [2026-10-24 21:19:31] AppID 242920 no longer tracking PID 2000, exit code -1
        [2026-10-24 21:19:31] Remove 242920 from running list
        [2026-10-24 21:19:58] AppID 242920 adding PID 384 as a tracked process ""C:\\Steam\\Banished.exe""
        [2026-10-24 21:19:58] AppID 228980 adding PID 390 as a tracked process ""C:\\Other.exe""

        """

    @Test func followsAGameThatStartsItselfAgain() {
        var state = SteamGameLog.State()
        let lines = restart.split(separator: "\n").map(String.init)
        SteamGameLog.apply(lines[0], appID: "242920", to: &state)
        #expect(state == .init(running: true, lastExit: nil))
        SteamGameLog.apply(lines[1...2].joined(separator: "\n"), appID: "242920", to: &state)
        #expect(state == .init(running: false, lastExit: -1))
        SteamGameLog.apply(lines[3...].joined(separator: "\n"), appID: "242920", to: &state)
        #expect(state.running)

        SteamGameLog.apply("""
            [2026-10-24 21:20:47] AppID 242920 no longer tracking PID 384, exit code 0
            [2026-10-24 21:20:47] Remove 242920 from running list
            """, appID: "242920", to: &state)
        #expect(state == .init(running: false, lastExit: 0))
    }

    @Test func readsOnlyWhatSteamWroteSinceTheLaunch() throws {
        let temp = try TempFolder()
        let file = temp.url.appending(path: "gameprocess_log.txt")
        try "[x] AppID 242920 adding PID 1 as a tracked process\n".write(to: file, atomically: true, encoding: .utf8)
        let reader = SteamGameLog.Reader(file: file, appID: "242920")
        var state = SteamGameLog.State()
        reader.read(into: &state)
        #expect(!state.running)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        // Half a line: it counts once Steam finishes it.
        handle.write(Data("[y] AppID 242920 adding PID 2 as a tra".utf8))
        reader.read(into: &state)
        #expect(!state.running)
        handle.write(Data("cked process\n".utf8))
        try handle.close()
        reader.read(into: &state)
        #expect(state.running)

        // Steam started again with a new, shorter file.
        try "[z] Remove 242920 from running list\n".write(to: file, atomically: true, encoding: .utf8)
        reader.read(into: &state)
        #expect(!state.running)
    }
}

@Suite struct SteamStartCheckTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    func stuck(client: Bool = true, helper: Bool = false, log: TimeInterval?, at second: TimeInterval) -> Bool {
        SteamStartCheck.stuck(clientRunning: client, helperRunning: helper,
                              lastLogWrite: log.map { start.addingTimeInterval($0) }, startedAt: start,
                              now: start.addingTimeInterval(second))
    }

    @Test func clientSilentWithoutHelperIsStuck() {
        // Build 4: "Verification skipped" at 0 s, then nothing.
        #expect(!stuck(log: 0, at: 30))
        #expect(stuck(log: 0, at: 46))
    }

    @Test func steamStillWritingIsNot() {
        // Its first update writes bootstrap_log as it downloads.
        #expect(!stuck(log: 40, at: 60))
    }

    @Test func helperUpOrNoClientIsNot() {
        #expect(!stuck(helper: true, log: 0, at: 120))
        #expect(!stuck(client: false, log: 0, at: 120))
    }

    @Test func oldLogsCountFromTheLaunch() {
        // Logs last written an hour before this launch.
        #expect(!stuck(log: -3600, at: 20))
        #expect(stuck(log: -3600, at: 50))
    }
}
