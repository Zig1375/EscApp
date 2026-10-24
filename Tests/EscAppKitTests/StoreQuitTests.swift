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
