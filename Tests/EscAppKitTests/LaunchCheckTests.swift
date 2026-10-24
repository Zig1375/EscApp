@testable import EscAppKit
import Foundation
import Testing

@Suite struct LogDiagnosisTests {
    @Test func aMissingGameFileIsNotWorthRetrying() {
        let log = #"""
            0024:err:module:import_dll Library binkw32.dll (which is needed by L"Z:\\Games\\D2\\Game.exe") not found
            0024:err:module:loader_init Importing dlls for L"Z:\\Games\\D2\\Game.exe" failed, status c0000135
            """#
        let diagnosis = LogDiagnosis(log: log)
        #expect(diagnosis.problem == .missingFile("binkw32.dll"))
        #expect(!diagnosis.retryHelps)
    }

    @Test func aMissingBackendFileIs() {
        // DXMT's DXGI on a Wine build that has no winemetal.dll.
        let log = #"""
            err:module:import_dll Library winemetal.dll (needed by L"C:\\windows\\system32\\DXGI.DLL") not found
            err:module:import_dll Library DXGI.DLL (which is needed by L"C:\\windows\\system32\\d3d11.dll") not found
            """#
        #expect(LogDiagnosis(log: log).problem == .graphics)
        let gameNeedsD3D11 = #"err:module:import_dll Library d3d11.dll (which is needed by L"Z:\\g.exe") not found"#
        #expect(LogDiagnosis(log: gameNeedsD3D11).problem == .graphics)
    }

    @Test(arguments: [
        "err:   Failed to create metal view, it seems like your Wine has no exported symbols needed by DXMT.",
        "err:   D3D11CoreCreateDevice: Failed to create D3D11 device",
        "err:d3d:wined3d_device_create None of the requested D3D feature levels is supported",
        "[mvk-error] VK_ERROR_DEVICE_LOST: Vulkan device lost",
    ])
    func graphicsFailures(_ line: String) {
        let diagnosis = LogDiagnosis(log: "noise\n\(line)\nmore noise")
        #expect(diagnosis.problem == .graphics)
        #expect(diagnosis.retryHelps)
        #expect(diagnosis.evidence == line)
    }

    @Test func crashesAntiCheatAndDirectX12() {
        #expect(LogDiagnosis(log: "wine: Unhandled page fault on read access to 00000000 at address 0040100A")
            .problem == .crash)
        // A breakpoint is how many games quit, not a crash.
        #expect(LogDiagnosis(log: "wine: Unhandled exception 0x80000003 in thread 24").problem == nil)
        let antiCheat = LogDiagnosis(log: "err:module:import_dll Library x.dll\nLoading EasyAntiCheat_x64.dll")
        #expect(antiCheat.problem == .antiCheat("EasyAntiCheat"))
        #expect(!antiCheat.retryHelps)
        #expect(LogDiagnosis(log: "D3D12CreateDevice failed: 0x80004002").problem == .directX12)
        #expect(LogDiagnosis(log: "[EscApp] Launch\nall fine").problem == nil)
    }

    @Test func excerptKeepsErrorsOnce() {
        let log = "[EscApp] Backend dxvk\ninfo: fine\nerr:x:y broken\nerr:x:y broken\n\tdetail\n"
        #expect(LogDiagnosis(log: log).excerpt == ["[EscApp] Backend dxvk", "err:x:y broken"])
    }

    @Test func aStoreClientsMissingFileIsNotTheGames() {
        // Steam's cold start runs gldriverquery.exe, which can't find SDL2.dll.
        let steam = #"C:\\Program Files (x86)\\Steam"#
        let log = #"032c:err:module:import_dll Library SDL2.dll (which is needed by L""#
            + steam + #"\\bin\\gldriverquery.exe") not found"#
        #expect(LogDiagnosis(log: log).problem == nil)
        let game = #"032c:err:module:import_dll Library binkw32.dll (which is needed by L""#
            + steam + #"\\steamapps\\common\\G\\g.exe") not found"#
        #expect(LogDiagnosis(log: log + "\n" + game).problem == .missingFile("binkw32.dll"))
        #expect(LogDiagnosis(log: game + "\n" + log).problem == .missingFile("binkw32.dll"))
    }
}

@Suite struct AttemptJudgeTests {
    @Test func aWindowThatStaysUpWorks() {
        var judge = AttemptJudge(windowTimeout: 60)
        #expect(judge.observe(elapsed: 5, window: false, exitCode: nil, idle: false) == nil)
        #expect(judge.observe(elapsed: 8, window: true, exitCode: nil, idle: false) == nil)
        // The window may flicker away while the game switches modes; it counts from when it first appeared.
        #expect(judge.observe(elapsed: 20, window: false, exitCode: nil, idle: false) == nil)
        #expect(judge.observe(elapsed: 23, window: true, exitCode: nil, idle: false) == .working)
    }

    @Test func closingWithAnErrorFails() {
        var judge = AttemptJudge(windowTimeout: 60)
        #expect(judge.observe(elapsed: 1, window: true, exitCode: nil, idle: false) == nil)
        #expect(judge.observe(elapsed: 3, window: false, exitCode: 2, idle: false) == .failed(.closed(exitCode: 2)))
    }

    @Test func aLauncherThatExitsCleanlyIsWaitedOut() {
        var judge = AttemptJudge(windowTimeout: 60)
        // The launcher quits with 0 and the game starts in the same bottle.
        #expect(judge.observe(elapsed: 2, window: false, exitCode: 0, idle: false) == nil)
        #expect(judge.observe(elapsed: 10, window: true, exitCode: 0, idle: false) == nil)
        #expect(judge.observe(elapsed: 25, window: true, exitCode: 0, idle: false) == .working)
        var short = AttemptJudge(windowTimeout: 60)
        #expect(short.observe(elapsed: 3, window: true, exitCode: 0, idle: true) == .ended)
    }

    @Test func noWindowOnlyFailsWithATimeout() {
        var first = AttemptJudge(windowTimeout: 60)
        #expect(first.observe(elapsed: 59, window: false, exitCode: nil, idle: false) == nil)
        #expect(first.observe(elapsed: 61, window: false, exitCode: nil, idle: false) == .failed(.noWindow))
        var remembered = AttemptJudge(windowTimeout: nil)
        #expect(remembered.observe(elapsed: 600, window: false, exitCode: nil, idle: false) == nil)
    }
}

@Suite struct AttemptOrderTests {
    @Test func rememberedThenKnownThenRules() {
        let plan: [GraphicsBackend] = [.dxvk, .dxmt, .wined3d]
        #expect(BackendPlan.order(plan, remembered: nil, known: nil) == plan)
        #expect(BackendPlan.order(plan, remembered: .wined3d, known: nil) == [.wined3d, .dxvk, .dxmt])
        #expect(BackendPlan.order(plan, remembered: .dxmt, known: .wined3d) == [.dxmt, .wined3d, .dxvk])
        #expect(BackendPlan.order([.wined3d], remembered: nil, known: .dxvk) == [.dxvk, .wined3d])
    }
}

@Suite struct KnownGameTests {
    @Test func matchesByFileNameAndProduct() {
        let exe = URL(filePath: "/Games/Diablo II/Game.exe")
        #expect(KnownGame(exe: "game.exe").matches(executable: exe, productName: nil))
        #expect(KnownGame(exe: "Game.exe", product: "Diablo II").matches(executable: exe, productName: "Diablo II "))
        #expect(!KnownGame(exe: "Game.exe", product: "Diablo II").matches(executable: exe, productName: "Other"))
        #expect(!KnownGame(exe: "Diablo II.exe").matches(executable: exe, productName: nil))
    }

    @Test func unknownValuesAreIgnoredNotFatal() throws {
        let json = """
            {"format": 1, "runtimes": [], "games": [
              {"exe": "a.exe", "backend": "d3dmetal", "windows": "win95"},
              {"exe": "b.exe", "backend": "wined3d", "windows": "winxp"}]}
            """
        let games = try #require(try JSONDecoder().decode(RuntimeManifest.self, from: Data(json.utf8)).games)
        #expect(games[0].preferredBackend == nil && games[0].windowsVersion == nil)
        #expect(games[1].preferredBackend == .wined3d && games[1].windowsVersion == .windowsXP)
        let old = try JSONDecoder().decode(RuntimeManifest.self, from: Data(#"{"format": 1, "runtimes": []}"#.utf8))
        #expect(old.games == nil)
    }
}

@Suite struct GameWindowsTests {
    @Test func readsTheEnvironmentAfterTheArguments() {
        var bytes: [UInt8] = [2, 0, 0, 0]
        for part in ["/opt/wine/bin/wine", "", "", "wine", "game.exe", "WINEPREFIX=/b/1", "HOME=/u", "X"] {
            bytes += Array(part.utf8) + [0]
        }
        #expect(GameWindows.parseProcArgs(bytes) == ["WINEPREFIX": "/b/1", "HOME": "/u"])
        #expect(GameWindows.parseProcArgs([1, 0]).isEmpty)
    }

    @Test func readsItsOwnEnvironment() {
        let own = GameWindows.environment(of: getpid())
        #expect(own["HOME"] == ProcessInfo.processInfo.environment["HOME"])
    }
}

@Suite struct LaunchReportTests {
    @Test func listsTheAttemptsWithTheirEvidenceAndHidesTheHomeFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let game = GameRecord(id: GameID.make(), name: "Diablo II", executable: "\(home)Games/D2/Game.exe",
                              folder: "\(home)Games/D2", hasMarker: true, addedAt: Date())
        let crash = LogDiagnosis(log: """
            [EscApp] Executable \(home)Games/D2/Game.exe
            wine: Unhandled page fault on read access to 00000000 at address 0040100A
            """)
        let log = URL(filePath: "/l.log")
        // The report quotes the last attempt's log.
        let result = AutoLaunch.Result(game: game, attempts: [
            LaunchAttempt(backend: .wined3d, seconds: 60, failure: .noWindow, diagnosis: LogDiagnosis(log: ""),
                          log: log),
            LaunchAttempt(backend: .dxvk, seconds: 3, failure: .closed(exitCode: 5), diagnosis: crash, log: log),
        ], working: nil, log: log)
        let text = LaunchReport.text(result, runtime: "wine-11.0-escapp-2", macOS: "26.1", app: "0.1.0")

        #expect(text.hasPrefix("EscApp 0.1.0, macOS 26.1, runtime wine-11.0-escapp-2\nGame: Diablo II\n"))
        #expect(text.contains("Executable: Game.exe"))
        #expect(text.contains("- DXVK: closed after 3 s, exit code 5\n  wine: Unhandled page fault"))
        #expect(text.contains("- WineD3D: no window after 60 s"))
        #expect(text.contains("Last log, errors only:"))
        #expect(!text.contains(home))
        #expect(text.contains("~/Games/D2/Game.exe"))
    }
}

@Suite struct GameWindowLayerTests {
    @Test func topmostFullScreenWindowsCountButTrayIconsDont() {
        // A full-screen game made with WS_EX_TOPMOST sits at 21; it showed "no window" and was retried.
        #expect(GameWindows.isGameLayer(0) && GameWindows.isGameLayer(21) && GameWindows.isGameLayer(1000))
        #expect(!GameWindows.isGameLayer(24) && !GameWindows.isGameLayer(25))
    }
}
