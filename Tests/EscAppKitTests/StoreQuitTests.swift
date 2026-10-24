@testable import EscAppKit
import Foundation
import Testing

@Suite struct StoreQuitTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    /// `#expect` can't take a mutating call.
    func look(_ quit: inout StoreQuit, windows: Bool, game: Bool, at second: TimeInterval) -> Bool {
        quit.update(windows: windows, game: game, now: start.addingTimeInterval(second))
    }

    @Test func closedWindowQuitsAfterAMoment() {
        var quit = StoreQuit()
        #expect(!look(&quit, windows: true, game: false, at: 0))
        #expect(!look(&quit, windows: false, game: false, at: 3))
        #expect(!look(&quit, windows: false, game: false, at: 9))
        #expect(look(&quit, windows: false, game: false, at: 11.5))
    }

    @Test func windowComingBackKeepsTheClient() {
        var quit = StoreQuit()
        _ = look(&quit, windows: true, game: false, at: 0)
        _ = look(&quit, windows: false, game: false, at: 3)
        #expect(!look(&quit, windows: true, game: false, at: 6))
        #expect(!look(&quit, windows: false, game: false, at: 12))
    }

    @Test func neverUsedClientIsLeftAlone() {
        // Steam started silently for a game, still updating or signing in before the game appears.
        var quit = StoreQuit()
        #expect(!quit.watching)
        for second in stride(from: 0.0, to: 600, by: 3) {
            #expect(!look(&quit, windows: false, game: false, at: second))
        }
    }

    @Test func gameGetsALongerWait() {
        // Banished's second process comes 27 s after its first ended.
        var quit = StoreQuit()
        _ = look(&quit, windows: false, game: true, at: 0)
        #expect(quit.watching)
        #expect(!look(&quit, windows: false, game: false, at: 1))
        #expect(!look(&quit, windows: false, game: false, at: 30))
        #expect(look(&quit, windows: false, game: false, at: 61))
    }

    @Test func helperOutputParses() {
        let output = "2688\t1\tSteam\n0024:err:module:something\n2688\t0\tfoxisfox666\n12\t0\t\n"
        #expect(StoreWindows.parse(output) == [
            .init(pid: 2688, minimised: true, title: "Steam"),
            .init(pid: 2688, minimised: false, title: "foxisfox666"),
            .init(pid: 12, minimised: false, title: ""),
        ])
        #expect(StoreWindows.parse("").isEmpty)
    }

    @Test func helperIsBundled() {
        #expect(StoreWindows.program != nil)
    }

    @Test(arguments: [
        (#"C:\Program Files (x86)\Steam\steam.exe"#, true),
        (#"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper_real.exe"#, true),
        (#"C:\Program Files (x86)\Common Files\Steam\steamservice.exe"#, true),
        (#"C:\windows\system32\services.exe"#, true),
        (#"C:\WINDOWS\system32\explorer.exe"#, true),
        ("/Users/zig/Library/Application Support/EscApp/Runtime/wine/bin/wineserver", true),
        (#"Z:\Applications\EscApp.app\Contents\Resources\store-windows.exe"#, true),
        (#"C:\Program Files (x86)\Steam\steamapps\common\Banished\Application-x64.exe"#, false),
        (#"D:\SteamLibrary\steamapps\common\Portal 2\portal2.exe"#, false),
    ])
    func steamPrograms(program: String, isClient: Bool) {
        #expect(Store.steam.isClientProgram(program) == isClient)
    }

    @Test func otherStoresGames() {
        #expect(Store.epic.isClientProgram(#"C:\Program Files (x86)\Epic Games\Launcher\Portal\Binaries\Win64\x.exe"#))
        #expect(!Store.epic.isClientProgram(#"C:\Program Files\Epic Games\Hades\x64\Hades.exe"#))
        #expect(!Store.gog.isClientProgram(#"C:\Program Files (x86)\GOG Galaxy\Games\Witcher\witcher.exe"#))
        #expect(!Store.ubisoft.isClientProgram(
            #"C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\games\Rayman Legends\Rayman Legends.exe"#))
    }

    @Test func helpersOlderThanTheBrowserAreStrays() {
        let browser = Date(timeIntervalSince1970: 5000)
        let helpers: [SteamHelperSweep.Helper] = [
            .init(pid: 877, started: browser.addingTimeInterval(-2800), isBrowser: false),
            .init(pid: 31840, started: browser.addingTimeInterval(-10), isBrowser: false),
            .init(pid: 31923, started: browser, isBrowser: true),
            .init(pid: 31944, started: browser.addingTimeInterval(2), isBrowser: false),
            .init(pid: 32051, started: browser.addingTimeInterval(20), isBrowser: false),
        ]
        #expect(SteamHelperSweep.strays(helpers) == [877, 31840])
    }

    @Test func noBrowserMeansNoStrays() {
        let helpers: [SteamHelperSweep.Helper] = [
            .init(pid: 877, started: Date(timeIntervalSince1970: 1), isBrowser: false),
        ]
        #expect(SteamHelperSweep.strays(helpers).isEmpty)
    }

    @Test func helpersAreFoundByProgram() {
        let started = Date(timeIntervalSince1970: 10)
        let cef = #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\"#
        let processes: [WineProcesses.Process] = [
            .init(pid: 1, executable: "/w/bin/wine", program: #"C:\Program Files (x86)\Steam\steam.exe"#,
                  started: started),
            .init(pid: 2, executable: "/w/bin/wine", program: cef + "steamwebhelper.exe",
                  arguments: ["-nocrashdialog"], started: started),
            .init(pid: 3, executable: "/w/bin/wine", program: cef + "steamwebhelper_real.exe",
                  arguments: ["--type=renderer", "--no-sandbox"], started: started),
            .init(pid: 4, executable: "/w/bin/wine", program: cef + "steamwebhelper_real.exe", started: nil),
        ]
        #expect(SteamHelperSweep.helpers(in: processes) == [
            .init(pid: 2, started: started, isBrowser: true),
            .init(pid: 3, started: started, isBrowser: false),
        ])
    }

    @Test func startTimeOfThisProcess() throws {
        let started = try #require(WineProcesses.startTime(of: getpid()))
        #expect(started <= Date())
        #expect(Date().timeIntervalSince(started) < 24 * 3600)
    }
}

@Suite struct StoreQuitFoundRunningTests {
    @Test func clientFoundRunningHiddenIsQuit() {
        var quit = StoreQuit(used: true)
        let start = Date(timeIntervalSince1970: 0)
        let first = quit.update(windows: false, game: false, now: start)
        let later = quit.update(windows: false, game: false, now: start.addingTimeInterval(9))
        #expect(!first)
        #expect(later)
    }
}

@Suite struct SteamLaunchesTests {
    let utc = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_793_000_000)  // 2026-10-26 04:53:20 UTC

    func line(_ secondsAgo: TimeInterval, _ action: Int, _ task: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let time = formatter.string(from: now.addingTimeInterval(-secondsAgo))
        return "[\(time)] GameAction [AppID 242920, ActionID \(action)] : LaunchApp changed task to \(task) with \"\""
    }

    @Test func launchUnderWayCounts() {
        let log = [line(20, 2, "SynchronizingCloud"), line(15, 2, "RunningInstallScript"),
                   "[2026-10-26 04:53:10] STARTUP SlowJSMethodCall Apps.GetGameActionDetails took 1.1ms"]
            .joined(separator: "\n")
        #expect(SteamLaunches.inProgress(log: log, now: now, timeZone: utc))
    }

    @Test func finishedOrFailedLaunchDoesNot() {
        let completed = [line(40, 2, "CreatingProcess"), line(30, 2, "Completed")].joined(separator: "\n")
        let failed = [line(40, 3, "SynchronizingCloud"), line(30, 3, "Failed")].joined(separator: "\n")
        #expect(!SteamLaunches.inProgress(log: completed, now: now, timeZone: utc))
        #expect(!SteamLaunches.inProgress(log: failed, now: now, timeZone: utc))
        #expect(!SteamLaunches.inProgress(log: "", now: now, timeZone: utc))
    }

    @Test func oneOfTwoLaunchesUnderWay() {
        let log = [line(100, 2, "Completed"), line(10, 3, "DelayLaunch")].joined(separator: "\n")
        #expect(SteamLaunches.inProgress(log: log, now: now, timeZone: utc))
    }

    @Test func abandonedLaunchStopsCounting() {
        // The launch that waited for an answer about a session playing Spacewar elsewhere, never given.
        let log = line(6 * 60, 2, "KickingOtherSession")
        #expect(!SteamLaunches.inProgress(log: log, now: now, timeZone: utc))
    }
}

@Suite struct SteamDownloadsTests {
    let start = "[2026-10-24 22:30:43] Client version: 1792618285"

    func state(_ app: Int, _ text: String) -> String {
        "[2026-10-24 22:34:12] AppID \(app) state changed : \(text)"
    }

    @Test func downloadUnderWayCounts() {
        let log = [start, state(242920, "Update Required,Update Queued,"),
                   state(242920, "Update Required,Update Queued,Update Running,Update Started,"),
                   "[2026-10-24 22:34:13] AppID 242920 App update changed : Running Update,Downloading,Staging,"]
        #expect(SteamDownloads.inProgress(log: log.joined(separator: "\n")))
    }

    @Test func finishedOrQueuedDownloadDoesNot() {
        let finished = [start, state(242920, "Fully Installed,Update Queued,Update Running,"),
                        state(242920, "Fully Installed,Update Queued,"), state(242920, "Fully Installed,")]
        let queued = [start, state(228980, "Update Required,Update Queued,")]
        #expect(!SteamDownloads.inProgress(log: finished.joined(separator: "\n")))
        #expect(!SteamDownloads.inProgress(log: queued.joined(separator: "\n")))
        #expect(!SteamDownloads.inProgress(log: ""))
    }

    @Test func oneOfTwoGamesDownloading() {
        let log = [start, state(228980, "Update Required,Update Queued,Update Running,"),
                   state(242920, "Fully Installed,")]
        #expect(SteamDownloads.inProgress(log: log.joined(separator: "\n")))
    }

    @Test func downloadCutShortBeforeARestartDoesNot() {
        let log = [state(242920, "Update Required,Update Queued,Update Running,"), start]
        #expect(!SteamDownloads.inProgress(log: log.joined(separator: "\n")))
    }
}
