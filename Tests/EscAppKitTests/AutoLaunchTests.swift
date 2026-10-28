@testable import EscAppKit
import Foundation
import Synchronization
import Testing

/// The launch loop's decisions with scripted games: no Wine, and timings shrunk to fractions of a second.
@Suite struct AutoLaunchTests {
    /// What one attempt does, in seconds after it starts.
    struct Script: Sendable {
        var windowAt: TimeInterval?
        var exitAt: TimeInterval?
        var exitCode: Int32 = 0
        var log = ""

        /// Shows its window and plays until the player quits.
        static let works = Script(windowAt: 0.02, exitAt: 0.3)
        static func crashes(at seconds: TimeInterval = 0.05) -> Script {
            Script(exitAt: seconds, exitCode: 5,
                   log: "wine: Unhandled page fault on write access to 00000000 at address 0040100A")
        }
        static let missesAFile = Script(exitAt: 0.02, exitCode: 53, log: #"""
            err:module:import_dll Library binkw32.dll (which is needed by L"Z:\\g\\game.exe") not found
            """#)
        static let showsNothing = Script()
        /// An old game without its CD: a message box asking for it (a window), then it quits when it's closed.
        static let asksForDisc = Script(windowAt: 0.02, exitAt: 0.3, exitCode: 1, log: #"""
            0024:trace:msgbox:MSGBOX_OnInit L"Please insert the Probe Game CD into your CD-ROM drive."

            """#)
    }

    final class FakeAttempt: GameAttempt, @unchecked Sendable {
        let session: GameSession
        let startedAt = Date()
        let script: Script
        let logFile: URL
        var log: URL { logFile }
        private let state = Mutex<(stoppedAt: TimeInterval?, idleWatched: Bool)>((nil, false))

        init(script: Script, pid: Int32, logFile: URL) {
            self.script = script
            self.logFile = logFile
            session = GameSession(wine: Wine(root: URL(filePath: "/fake")), environment: [:], processID: pid)
            // Written as the game runs, as Wine's output is.
            try? script.log.write(to: logFile, atomically: true, encoding: .utf8)
        }

        var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }
        var stopped: Bool { state.withLock { $0.stoppedAt != nil } }
        private var exitTime: TimeInterval? {
            [script.exitAt, state.withLock { $0.stoppedAt }].compactMap(\.self).min()
        }

        var hasWindow: Bool {
            guard let windowAt = script.windowAt, elapsed >= windowAt else { return false }
            return exitTime.map { elapsed < $0 } ?? true
        }

        var exitCode: Int32? {
            guard let exitTime, elapsed >= exitTime else { return nil }
            return script.exitAt == exitTime ? script.exitCode : 1
        }

        var isIdle: Bool { exitCode != nil && state.withLock { $0.idleWatched } }
        func watchForIdle() { state.withLock { $0.idleWatched = true } }
        func stop() async { state.withLock { $0.stoppedAt = $0.stoppedAt ?? elapsed } }

        func finish() async -> GameLauncher.Outcome {
            while exitCode == nil { try? await Task.sleep(for: .milliseconds(5)) }
            try? script.log.write(to: logFile, atomically: true, encoding: .utf8)
            return GameLauncher.Outcome(exitCode: exitCode ?? -1, duration: elapsed, processDuration: elapsed,
                                        backend: .dxvk, log: logFile)
        }
    }

    final class FakeStarter: AttemptStarter, @unchecked Sendable {
        let scripts: [GraphicsBackend: Script]
        let logs: URL
        private let state = Mutex<[(GraphicsBackend, FakeAttempt)]>([])
        private let games = Mutex<[GameRecord]>([])

        init(_ scripts: [GraphicsBackend: Script], logs: URL) {
            self.scripts = scripts
            self.logs = logs
        }

        var started: [(GraphicsBackend, FakeAttempt)] { state.withLock { $0 } }
        /// The game as each attempt got it.
        var startedGames: [GameRecord] { games.withLock { $0 } }

        func start(_ game: GameRecord, runtime: RuntimeManifest.Runtime, backend: GraphicsBackend, verboseLog: Bool,
                   progress: @Sendable (GameLauncher.Step) -> Void) async throws -> any GameAttempt {
            let pid = Int32(state.withLock { $0.count } + 100)
            let attempt = FakeAttempt(script: scripts[backend] ?? .showsNothing, pid: pid,
                                      logFile: logs.appending(path: "\(pid).log"))
            state.withLock { $0.append((backend, attempt)) }
            games.withLock { $0.append(game) }
            return attempt
        }

        func windows(_ session: GameSession) -> [Int32] {
            started.contains { $0.1.session.processID == session.processID && $0.1.hasWindow }
                ? [session.processID] : []
        }
    }

    actor FakeWarmer: WarmBottles {
        var calls: [String] = []
        /// When `release` first came.
        var releasedAt: Date?

        func release(_ id: GameID) {
            calls.append("release")
            releasedAt = releasedAt ?? Date()
        }

        func coolAll(except kept: GameID?) { calls.append("coolAll") }
    }

    let temp: TempFolder
    let paths: AppPaths
    var game: GameRecord
    let runtime = RuntimeManifest.Runtime(id: "test", minApp: Version("0.1")!, minMacOS: Version("15")!,
                                          components: [])
    let timing = AutoLaunch.Timing(poll: .milliseconds(5), windowHolds: 0.1, firstWindowTimeout: 0.2,
                                   handOverAfter: 0.15)

    init() throws {
        temp = try TempFolder()
        paths = AppPaths(root: temp.url.appending(path: "Home"), games: temp.url.appending(path: "Games"))
        // A D3D11 x64 exe: the rules try DXVK, then DXMT, then WineD3D.
        let exe = temp.url.appending(path: "Game/game.exe")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Probes.url("d3d11-x64"), to: exe)
        game = try GameIdentifier(paths: paths).identify(executable: exe).record
    }

    /// What the scripted game's window measures, as `GameWindows.learnWindow` would report it.
    static let window = GameScaling.LearnedWindow(width: 640, height: 508, fullScreen: false)

    func play(_ starter: FakeStarter, backend: GraphicsBackend? = nil, knownGames: [KnownGame] = [],
              control: LaunchControl = LaunchControl(), warmer: FakeWarmer? = nil,
              events: @escaping @Sendable (AutoLaunch.Event) -> Void = { _ in }) async throws -> AutoLaunch.Result {
        try await AutoLaunch(paths: paths, starter: starter, windows: starter.windows, measure: { _ in Self.window },
                             timing: timing)
            .play(game, runtime: runtime, backend: backend, knownGames: knownGames, control: control,
                  warmer: warmer, events: events)
    }

    func logs() throws -> URL {
        let folder = temp.url.appending(path: "Logs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func remembered() throws -> GraphicsBackend? { try GameLibrary.load(from: paths.library)[game.id]?.backend }

    @Test func aGameThatWorksNeedsOneAttempt() async throws {
        let starter = try FakeStarter([.dxvk: .works], logs: logs())
        let learned = Mutex<Bool?>(nil)
        let result = try await play(starter) { event in
            if case let .working(_, wasLearned) = event { learned.withLock { $0 = wasLearned } }
        }
        #expect(result.working == .dxvk)
        #expect(result.attempts.count == 1)
        #expect(learned.withLock { $0 } == false)
        #expect(try remembered() == .dxvk)
        #expect(try GameLibrary.load(from: paths.library)[game.id]?.launches == 1)
        // Its window size is kept: it sets how much the game is enlarged next time.
        #expect(try GameLibrary.load(from: paths.library)[game.id]?.window == Self.window)
    }

    @Test func aCrashMovesOnToTheNextBackendAndIsLearned() async throws {
        let starter = try FakeStarter([.dxvk: .crashes(), .dxmt: .works], logs: logs())
        let retries = Mutex<[GraphicsBackend]>([])
        let result = try await play(starter) { event in
            if case let .retrying(_, next, _, _) = event { retries.withLock { $0.append(next) } }
        }
        #expect(starter.started.map(\.0) == [.dxvk, .dxmt])
        #expect(retries.withLock { $0 } == [.dxmt])
        #expect(result.working == .dxmt)
        #expect(result.learned)
        #expect(result.attempts.first?.failure == .closed(exitCode: 5))
        #expect(result.attempts.first?.diagnosis.problem == .crash)
        #expect(try remembered() == .dxmt)
    }

    @Test func graphicsPickedByHandIsTheOnlyOneTried() async throws {
        var picked = game
        picked.chosenBackend = .wined3d
        let starter = try FakeStarter([.wined3d: .crashes(), .dxvk: .works], logs: logs())
        let result = try await AutoLaunch(paths: paths, starter: starter, windows: starter.windows,
                                          measure: { _ in nil }, timing: timing)
            .play(picked, runtime: runtime)
        #expect(starter.started.map(\.0) == [.wined3d])
        #expect(result.attempts.count == 1)
    }

    @Test func aMissingGameFileEndsTheTriesAtOnce() async throws {
        let starter = try FakeStarter([.dxvk: .missesAFile, .dxmt: .works], logs: logs())
        let result = try await play(starter)
        #expect(starter.started.map(\.0) == [.dxvk])
        #expect(result.working == nil)
        #expect(result.attempts.first?.diagnosis.problem == .missingFile("binkw32.dll"))
        #expect(try remembered() == nil)
    }

    @Test func nothingWorkingTriesEveryBackendAndStopsEach() async throws {
        let starter = try FakeStarter([:], logs: logs())
        let result = try await play(starter)
        #expect(starter.started.map(\.0) == [.dxvk, .dxmt, .wined3d])
        #expect(result.attempts.allSatisfy { $0.failure == .noWindow })
        #expect(starter.started.allSatisfy { $0.1.stopped })
        #expect(result.working == nil)
    }

    @Test mutating func aRememberedBackendIsNeverKilledForTakingLong() async throws {
        try GameLibrary.modify(paths.library) { $0[game.id]?.backend = .dxmt }
        game.backend = .dxmt
        // No window for longer than a new backend would be given, then a clean exit.
        let starter = try FakeStarter([.dxmt: Script(exitAt: 0.4)], logs: logs())
        let result = try await play(starter)
        #expect(starter.started.map(\.0) == [.dxmt])
        #expect(starter.started.first?.1.stopped == false)
        #expect(result.working == .dxmt)
    }

    @Test func dontRetryLetsTheRunningAttemptGoOnUnjudged() async throws {
        let starter = try FakeStarter([.dxvk: .crashes(at: 0.1), .dxmt: .works], logs: logs())
        let control = LaunchControl()
        let result = try await play(starter, control: control) { event in
            if case .started = event { control.stopRetrying() }
        }
        #expect(starter.started.map(\.0) == [.dxvk])
        #expect(starter.started.first?.1.stopped == false)
        #expect(result.attempts.first?.failure == nil)
        #expect(result.working == nil)
        #expect(try remembered() == nil)
    }

    @Test func aChosenBackendIsTheOnlyTry() async throws {
        let starter = try FakeStarter([.wined3d: .crashes()], logs: logs())
        let result = try await play(starter, backend: .wined3d)
        #expect(starter.started.map(\.0) == [.wined3d])
        #expect(result.working == nil)
    }

    @Test func cancellingStopsTheGame() async throws {
        let starter = try FakeStarter([:], logs: logs())
        let launch = AutoLaunch(paths: paths, starter: starter, windows: starter.windows, timing: timing)
        let (game, runtime) = (game, runtime)
        let task = Task { try await launch.play(game, runtime: runtime) }
        while starter.started.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(starter.started.count == 1)
        #expect(starter.started.first?.1.stopped == true)
    }

    @Test func theGameDatabaseSetsWindowsForAFirstLaunch() async throws {
        let starter = try FakeStarter([.dxvk: .works], logs: logs())
        let known = KnownGame(exe: "game.exe", windows: "winxp")
        let result = try await play(starter, knownGames: [known])
        #expect(result.game.windowsVersion == .windowsXP)
        #expect(try GameLibrary.load(from: paths.library)[game.id]?.windowsVersion == .windowsXP)
    }

    @Test func theGameDatabaseBackendGoesFirst() async throws {
        let starter = try FakeStarter([.wined3d: .works], logs: logs())
        _ = try await play(starter, knownGames: [KnownGame(exe: "GAME.EXE", backend: "wined3d")])
        #expect(starter.started.map(\.0) == [.wined3d])
    }

    @Test func aWarmBottleIsHandedOverOnlyOnceTheGameShowsAWindow() async throws {
        let starter = try FakeStarter([.dxvk: Script(windowAt: 0.08, exitAt: 0.3)], logs: logs())
        let warmer = FakeWarmer()
        _ = try await play(starter, warmer: warmer)
        #expect(await warmer.calls.first == "coolAll")
        let start = try #require(starter.started.first?.1.startedAt)
        let after = try #require(await warmer.releasedAt).timeIntervalSince(start)
        #expect(after >= 0.08)
    }

    @Test func aWarmBottleIsHandedOverAfterAWhileWithoutAWindow() async throws {
        // Not `var game = game`: Swift 6.0 (CI) rejects the closure above capturing a name declared after it.
        let id = game.id
        try GameLibrary.modify(paths.library) { $0[id]?.backend = .dxvk }
        var played = game
        played.backend = .dxvk
        let starter = try FakeStarter([.dxvk: Script(exitAt: 0.4)], logs: logs())
        let warmer = FakeWarmer()
        _ = try await AutoLaunch(paths: paths, starter: starter, windows: starter.windows, timing: timing)
            .play(played, runtime: runtime, warmer: warmer)
        let start = try #require(starter.started.first?.1.startedAt)
        let after = try #require(await warmer.releasedAt).timeIntervalSince(start)
        #expect(after >= timing.handOverAfter && after < 0.4)
    }
}

extension AutoLaunchTests {
    @Test func aRequestForTheCDIsReportedAtOnceAndNotRetried() async throws {
        let starter = try FakeStarter([.dxvk: .asksForDisc, .dxmt: .works], logs: logs())
        let asked = Mutex<Date?>(nil)
        let text = Mutex<String?>(nil)
        let started = Date()
        let result = try await play(starter) { event in
            if case let .asksForDisc(message) = event {
                asked.withLock { $0 = $0 ?? Date() }
                text.withLock { $0 = message }
            }
        }
        // While the box is still up, not once the game has quit.
        #expect(try #require(asked.withLock { $0 }).timeIntervalSince(started) < 0.25)
        #expect(text.withLock { $0 } == "Please insert the Probe Game CD into your CD-ROM drive.")
        #expect(starter.started.map(\.0) == [.dxvk])
        #expect(result.attempts.last?.diagnosis.problem == .needsDisc)
        #expect(result.working == nil)
    }
}

extension AutoLaunchTests {
    @Test func aStoreGameGetsOneTryAndWaitsForItsWindow() async throws {
        var steamGame = game
        steamGame.store = .steam
        steamGame.storeID = "400"
        // Steam may sit at its sign-in for longer than a first window may take: no timeout, no other backend.
        let starter = try FakeStarter([.dxvk: Script(windowAt: 0.4, exitAt: 0.7), .dxmt: .works], logs: logs())
        let result = try await AutoLaunch(paths: paths, starter: starter, windows: starter.windows,
                                          measure: { _ in nil }, timing: timing)
            .play(steamGame, runtime: runtime)
        #expect(starter.started.map(\.0) == [.dxvk])
        #expect(result.working == .dxvk)
    }
}

extension AutoLaunchTests {
    @Test func aFirstLaunchOnAutoSaysItIsLookingForSettingsBeforeAnythingElse() async throws {
        let starter = try FakeStarter([.dxvk: .crashes(), .dxmt: .works], logs: logs())
        let events = Mutex<[String]>([])
        _ = try await play(starter) { event in
            let name = switch event {
            case let .tuning(order): "tuning " + order.map(\.rawValue).joined(separator: ",")
            case .checking: "checking"
            case .started: "started"
            default: ""
            }
            if !name.isEmpty { events.withLock { if $0.last != name { $0.append(name) } } }
        }
        let seen = events.withLock { $0 }
        #expect(seen.first == "tuning dxvk,dxmt,wined3d")
        #expect(seen.contains("checking"))

        // Once a backend is known to work, the next launch is an ordinary one.
        var next = try #require(GameLibrary.load(from: paths.library)[game.id])
        #expect(!AutoLaunch.isTuning(next, order: [.dxmt, .dxvk], retrying: true))
        next.backend = nil
        #expect(AutoLaunch.isTuning(next, order: [.dxvk, .dxmt], retrying: true))
        #expect(!AutoLaunch.isTuning(next, order: [.dxvk], retrying: true))
        #expect(!AutoLaunch.isTuning(next, order: [.dxvk, .dxmt], retrying: false))
        next.chosenBackend = .dxvk
        #expect(!AutoLaunch.isTuning(next, order: [.dxvk, .dxmt], retrying: true))
    }
}

extension AutoLaunchTests {
    /// A module that requires D3DMetal, without D3DMetal added: the launch stops at the DirectX 12 setup instead
    /// of starting the game on DXVK to fail.
    @Test func aModuleRequiringD3DMetalWithoutItStartsNothing() async throws {
        let module = GameModule(id: "dx12", revision: 1, format: 1, name: "DX12",
                                match: .init(exe: [.init(name: "game.exe")]),
                                fixes: [.init(launch: .init(require: .init(backend: ["d3dmetal"])))])
        let starter = try FakeStarter([.dxvk: .works], logs: logs())
        await #expect(throws: LaunchError.self) {
            try await AutoLaunch(paths: paths, starter: starter, windows: starter.windows,
                                 measure: { _ in nil }, timing: timing)
                .play(game, runtime: runtime, modules: [module])
        }
        #expect(starter.started.isEmpty)
    }
}
