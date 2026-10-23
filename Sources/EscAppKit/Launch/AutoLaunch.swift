import Foundation
import Synchronization

/// Plays a game, and when it fails at start, plays it again with the next graphics backend (the first-run check
/// in ARCHITECTURE.md). Records the result in `Games.json`: play time, and the backend that worked.
///
/// An attempt works once the game's window has stayed up for `AttemptJudge.windowHolds`, or the game ended
/// cleanly with nothing fatal in its log. It fails when the game quits with an error code before that, or shows
/// no window in time on a backend that never worked for it. A failure whose log shows another backend can't
/// help (a missing game file, anti-cheat) ends the loop at once.
public struct AutoLaunch: Sendable {
    public enum Event: Sendable {
        case preparing(GameLauncher.Step)
        /// Attempt `attempt` (from 1) of `total` is running.
        case started(GameSession, backend: GraphicsBackend, attempt: Int, total: Int)
        /// The game has a window on screen, owned by `pid`.
        case windowShown(pid: Int32)
        /// The attempt works; the game plays on. `learned` when earlier attempts failed, so the player should hear
        /// what EscApp settled on.
        case working(GraphicsBackend, learned: Bool)
        /// An attempt failed and the next one starts with `next`.
        case retrying(LaunchAttempt, next: GraphicsBackend, attempt: Int, total: Int)
    }

    public struct Result: Sendable {
        public var game: GameRecord
        public var attempts: [LaunchAttempt]
        /// The backend that worked, now remembered for the game. Nil when nothing did.
        public var working: GraphicsBackend?
        /// The last attempt's log.
        public var log: URL?

        /// A backend was found by trying: worth telling the player what was learned.
        public var learned: Bool { working != nil && attempts.count > 1 }
    }

    let paths: AppPaths
    let host: [String: String]
    /// The game's window owners under a Wine folder; injectable so the loop doesn't depend on the screen.
    let windows: @Sendable (URL) -> [Int32]

    public init(paths: AppPaths, host: [String: String] = ProcessInfo.processInfo.environment,
                windows: @escaping @Sendable (URL) -> [Int32] = GameWindows.owners(under:)) {
        self.paths = paths
        self.host = host
        self.windows = windows
    }

    /// - Parameters:
    ///   - backend: plays with exactly this backend, without retrying (`escapp run --backend`).
    ///   - knownGames: the manifest's game database.
    public func play(_ game: GameRecord, runtime: RuntimeManifest.Runtime, backend override: GraphicsBackend? = nil,
                     knownGames: [KnownGame] = [], verboseLog: Bool = false, control: LaunchControl = LaunchControl(),
                     events: @escaping @Sendable (Event) -> Void = { _ in }) async throws -> Result {
        var game = game
        let exe = URL(filePath: game.executable)
        let info = try? ExecutableInfo.read(exe)
        let known = KnownGame.find(in: knownGames, executable: exe, productName: info?.productName)
        if (game.launches ?? 0) == 0, let windows = known?.windowsVersion, windows != game.windowsVersion {
            game.windowsVersion = windows
            try update(game.id) { $0.windowsVersion = windows }
        }

        let order: [GraphicsBackend]
        if let override {
            order = [override]
            control.stopRetrying()
        } else if case let .attempts(plan)? = info.map({ BackendPlan.forTraits($0.traits) }) {
            order = BackendPlan.order(plan, remembered: game.backend, known: known?.preferredBackend)
        } else {
            // Unsupported or unreadable: `prepare` throws the reason.
            order = [game.backend ?? .dxvk]
        }

        let launcher = GameLauncher(paths: paths, host: host)
        var attempts: [LaunchAttempt] = []
        for (index, backend) in order.enumerated() {
            let prepared = try await launcher.prepare(game, runtime: runtime, backend: backend,
                                                      verboseLog: verboseLog) { events(.preparing($0)) }
            try Task.checkCancellation()
            let running = try launcher.start(prepared)
            events(.started(running.session, backend: backend, attempt: index + 1, total: order.count))

            // A backend that worked before only fails by closing; one never seen working also by showing nothing.
            let timeout = backend == game.backend ? nil : AttemptJudge.firstWindowTimeout
            let verdict = try await watch(running, timeout: timeout, control: control, events: events)
            if case .failed = verdict { await running.session.stop() }
            if verdict == .working { events(.working(backend, learned: index > 0)) }
            let outcome = await running.finish()
            let diagnosis = LogDiagnosis(log: LogDiagnosis.read(outcome.log) ?? "")
            let failure: AttemptJudge.Failure? = switch verdict {
            case let .failed(failure)?: failure
            case .ended?: diagnosis.problem.map { _ in .closed(exitCode: outcome.exitCode) }
            case .working?, nil: nil
            }
            let attempt = LaunchAttempt(backend: backend, seconds: Int(outcome.processDuration), failure: failure,
                                        diagnosis: diagnosis, log: outcome.log)
            attempts.append(attempt)

            let worked = verdict == .working || (verdict == .ended && failure == nil)
            if worked || verdict == nil || index == order.count - 1 || !diagnosis.retryHelps || !control.retrying {
                // A run that wasn't judged (the player said not to retry) only teaches its play time.
                try record(game.id, duration: outcome.duration, working: worked ? backend : nil)
                return Result(game: game, attempts: attempts, working: worked ? backend : nil, log: outcome.log)
            }
            events(.retrying(attempt, next: order[index + 1], attempt: index + 2, total: order.count))
        }
        return Result(game: game, attempts: attempts, working: nil, log: attempts.last?.log)
    }

    /// Watches the attempt until it is decided, or until it ends when the player stopped the checking.
    /// Returns nil for an attempt that ran unjudged.
    private func watch(_ running: RunningGame, timeout: TimeInterval?, control: LaunchControl,
                       events: @Sendable (Event) -> Void) async throws -> AttemptJudge.Verdict? {
        var judge = AttemptJudge(windowTimeout: timeout)
        var announced = false
        while true {
            let owners = windows(running.session.wineRoot)
            if let owner = owners.first, !announced {
                announced = true
                events(.windowShown(pid: owner))
            }
            if running.exitCode != nil { running.watchForIdle() }
            if !control.retrying {
                // Not judging any more: the game just runs; `finish` waits for its end.
                return nil
            }
            let elapsed = Date().timeIntervalSince(running.startedAt)
            if let verdict = judge.observe(elapsed: elapsed, window: !owners.isEmpty, exitCode: running.exitCode,
                                           idle: running.isIdle) {
                return verdict
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                await running.session.stop()
                _ = await running.finish()
                throw error
            }
        }
    }

    private func record(_ id: GameID, duration: TimeInterval, working: GraphicsBackend?) throws {
        var library = try GameLibrary.load(from: paths.library)
        library.recordPlay(of: id, duration: duration, working: working)
        try library.save(to: paths.library)
    }

    private func update(_ id: GameID, _ change: (inout GameRecord) -> Void) throws {
        var library = try GameLibrary.load(from: paths.library)
        guard var game = library[id] else { return }
        change(&game)
        library[id] = game
        try library.save(to: paths.library)
    }
}

/// One try with one backend.
public struct LaunchAttempt: Sendable, Equatable {
    public var backend: GraphicsBackend
    /// How long the game's process ran.
    public var seconds: Int
    /// Nil when it worked (or ran unjudged).
    public var failure: AttemptJudge.Failure?
    public var diagnosis: LogDiagnosis
    public var log: URL
}

/// Lets the player stop the checking from the launch sheet ("Don't retry"): the attempt that is running then
/// just keeps running, and no further one starts.
public final class LaunchControl: Sendable {
    private let state = Mutex(true)

    public init() {}

    public var retrying: Bool { state.withLock { $0 } }

    public func stopRetrying() {
        state.withLock { $0 = false }
    }
}
