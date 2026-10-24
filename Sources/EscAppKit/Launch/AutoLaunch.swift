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
        /// EscApp is looking for the settings the game works with (`isTuning`), trying these backends in this
        /// order. Comes before everything else; without it the launch is an ordinary one.
        case tuning([GraphicsBackend])
        case preparing(GameLauncher.Step)
        /// Attempt `attempt` (from 1) of `total` is running.
        case started(GameSession, backend: GraphicsBackend, attempt: Int, total: Int)
        /// The game has a window on screen, owned by `pid`.
        case windowShown(pid: Int32)
        /// The window has stayed up `held` of the `needed` seconds that make the attempt count as working. Once a
        /// second while the attempt is judged.
        case checking(held: Int, needed: Int)
        /// The attempt works; the game plays on. `learned` when earlier attempts failed, so the player should hear
        /// what EscApp settled on.
        case working(GraphicsBackend, learned: Bool)
        /// The game asked for its CD in a message box and waits for it (`LogDiagnosis.asksForDisc`), with the box's
        /// text.
        case asksForDisc(String)
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
    /// Starts each attempt: `GameLauncher`, or a script in tests.
    let starter: any AttemptStarter
    /// The game's window owners; injectable so the loop doesn't depend on the screen.
    let windows: @Sendable (GameSession) -> [Int32]
    /// The game's window size once it works, which decides how much it is enlarged next time (`GameScaling`).
    let measure: @Sendable (GameSession) -> GameScaling.LearnedWindow?
    let timing: Timing

    public init(paths: AppPaths, host: [String: String] = ProcessInfo.processInfo.environment,
                starter: (any AttemptStarter)? = nil,
                windows: @escaping @Sendable (GameSession) -> [Int32] = GameWindows.owners(of:),
                measure: @escaping @Sendable (GameSession) -> GameScaling.LearnedWindow? = GameWindows.learnWindow(of:),
                timing: Timing = .standard) {
        self.paths = paths
        self.starter = starter ?? GameLauncher(paths: paths, host: host)
        self.windows = windows
        self.measure = measure
        self.timing = timing
    }

    /// - Parameters:
    ///   - backend: plays with exactly this backend, without retrying (`escapp run --backend`).
    ///   - knownGames: the manifest's game database.
    ///   - warmer: holds the game's bottle warm, if it does; the game takes it over once it runs.
    public func play(_ game: GameRecord, runtime: RuntimeManifest.Runtime, backend override: GraphicsBackend? = nil,
                     knownGames: [KnownGame] = [], verboseLog: Bool = false, control: LaunchControl = LaunchControl(),
                     warmer: (any WarmBottles)? = nil,
                     events: @escaping @Sendable (Event) -> Void = { _ in }) async throws -> Result {
        // The other warm bottles go: the game gets the memory. Its own is handed over once it runs.
        await warmer?.coolAll(except: game.id)
        // The CD goes back out once the game is over, or didn't start.
        let disc = game.disc.map { URL(filePath: $0) }
        do {
            let result = try await attempts(game, runtime: runtime, backend: override, knownGames: knownGames,
                                            context: Context(runtime: runtime, verboseLog: verboseLog,
                                                             control: control, warmer: warmer, events: events))
            if let disc { await DiscImage.detach(image: disc, paths: paths) }
            return result
        } catch {
            if let disc { await DiscImage.detach(image: disc, paths: paths) }
            throw error
        }
    }

    private func attempts(_ game: GameRecord, runtime: RuntimeManifest.Runtime, backend override: GraphicsBackend?,
                          knownGames: [KnownGame], context: Context) async throws -> Result {
        let control = context.control
        let events = context.events
        var game = game
        let exe = URL(filePath: game.executable)
        let info = try? ExecutableInfo.read(exe)
        let known = KnownGame.find(in: knownGames, executable: exe, productName: info?.productName)
        if (game.launches ?? 0) == 0, let windows = known?.windowsVersion, windows != game.windowsVersion {
            game.windowsVersion = windows
            try update(game.id) { $0.windowsVersion = windows }
        }

        let order: [GraphicsBackend]
        // Graphics picked in Advanced works like `--backend`: that one only, no retries.
        if let override = override ?? game.chosenBackend {
            order = [override]
            control.stopRetrying()
        } else if case let .attempts(plan)? = info.map({ BackendPlan.forTraits($0.traits) }) {
            let planned = BackendPlan.order(plan, remembered: game.backend, known: known?.preferredBackend)
            // A store game gets one try: another backend means restarting the store's client, and its first start
            // may sit behind the store's sign-in or an update for as long as those take.
            order = game.store == nil ? planned : Array(planned.prefix(1))
        } else {
            // Unsupported or unreadable: `prepare` throws the reason.
            order = [game.backend ?? .dxvk]
        }

        if Self.isTuning(game, order: order, retrying: control.retrying) { events(.tuning(order)) }
        var attempts: [LaunchAttempt] = []
        for (index, backend) in order.enumerated() {
            let ran = try await attempt(backend, of: game, number: index + 1, of: order.count, context: context)
            attempts.append(ran.attempt)
            let last = index == order.count - 1 || !ran.attempt.diagnosis.retryHelps || !control.retrying
            if ran.worked || !ran.judged || last {
                // A run that wasn't judged (the player said not to retry) only teaches its play time.
                try record(game.id, duration: ran.duration, working: ran.worked ? backend : nil)
                return Result(game: game, attempts: attempts, working: ran.worked ? backend : nil,
                              log: ran.attempt.log)
            }
            events(.retrying(ran.attempt, next: order[index + 1], attempt: index + 2, total: order.count))
        }
        return Result(game: game, attempts: attempts, working: nil, log: attempts.last?.log)
    }

    /// A launch that looks for the game's settings: on Auto graphics, with nothing known to work yet and more than
    /// one backend to try. The app hides the game's window meanwhile, since a failing attempt can flash it open
    /// and shut; a store game gets one try, so it never tunes.
    static func isTuning(_ game: GameRecord, order: [GraphicsBackend], retrying: Bool) -> Bool {
        retrying && order.count > 1 && game.backend == nil && game.chosenBackend == nil && game.store == nil
    }

    /// What one launch keeps the same across its attempts.
    private struct Context: Sendable {
        let runtime: RuntimeManifest.Runtime
        let verboseLog: Bool
        let control: LaunchControl
        let warmer: (any WarmBottles)?
        let events: @Sendable (Event) -> Void
    }

    /// How one attempt went, to the end of the game.
    private struct Ran {
        var attempt: LaunchAttempt
        var worked: Bool
        /// False when the player stopped the checking and the game just ran.
        var judged: Bool
        /// Until everything in the bottle stopped: the play time.
        var duration: TimeInterval
    }

    private func attempt(_ backend: GraphicsBackend, of game: GameRecord, number: Int, of total: Int,
                         context: Context) async throws -> Ran {
        let running = try await starter.start(game, runtime: context.runtime, backend: backend,
                                              verboseLog: context.verboseLog) { context.events(.preparing($0)) }
        if Task.isCancelled {
            await running.stop()
            _ = await running.finish()
            throw CancellationError()
        }
        context.events(.started(running.session, backend: backend, attempt: number, total: total))

        // A backend that worked before only fails by closing; one never seen working also by showing nothing.
        let timeout = backend == game.backend || game.store != nil ? nil : timing.firstWindowTimeout
        var seen: GameScaling.LearnedWindow?
        let verdict = try await watch(running, game: game.id, timeout: timeout, context: context, seen: &seen)
        // The bottle only goes idle once the warm-up's helper is gone.
        await context.warmer?.release(game.id)
        if case .failed = verdict { await running.stop() }
        if verdict == .working { context.events(.working(backend, learned: number > 1)) }
        let outcome = await running.finish()
        let diagnosis = LogDiagnosis(log: LogDiagnosis.read(outcome.log) ?? "")
        var failure: AttemptJudge.Failure? = switch verdict {
        case let .failed(failure)?: failure
        case .ended?: diagnosis.problem.map { _ in .closed(exitCode: outcome.exitCode) }
        case .working?, nil: nil
        }
        // Its "Please insert the CD" box stays up as long as the player leaves it: that window isn't the game.
        let askedForDisc = diagnosis.problem == .needsDisc
        if askedForDisc { failure = failure ?? .closed(exitCode: outcome.exitCode) }
        let attempt = LaunchAttempt(backend: backend, seconds: Int(outcome.processDuration), failure: failure,
                                    diagnosis: diagnosis, log: outcome.log)
        let worked = !askedForDisc && (verdict == .working || (verdict == .ended && failure == nil))
        // The window it last had sets how much the game is enlarged next time.
        if worked || verdict == nil, let seen { try? update(game.id) { $0.window = seen } }
        return Ran(attempt: attempt, worked: worked, judged: verdict != nil, duration: outcome.duration)
    }

    /// Watches the attempt until it is decided, or until it ends when the player stopped the checking.
    /// Returns nil for an attempt that ran unjudged.
    /// - Parameter seen: the game's window, measured while it is on screen.
    private func watch(_ running: any GameAttempt, game: GameID, timeout: TimeInterval?, context: Context,
                       seen: inout GameScaling.LearnedWindow?) async throws -> AttemptJudge.Verdict? {
        var judge = AttemptJudge(windowTimeout: timeout, windowHolds: timing.windowHolds)
        var announced = false
        var held: Int?
        // An old game asking for its CD shows a message box and waits: its window counts as the game's, so the
        // request is caught from the log as it is written, not after the game ends.
        let tail = LogTail(running.log)
        var askedForDisc = false
        while true {
            if !askedForDisc, let line = tail.newLines().first(where: LogDiagnosis.asksForDisc) {
                askedForDisc = true
                context.events(.asksForDisc(LogDiagnosis.messageText(line)))
            }
            let owners = windows(running.session)
            if !owners.isEmpty, let window = measure(running.session) { seen = window }
            if let owner = owners.first, !announced {
                announced = true
                context.events(.windowShown(pid: owner))
            }
            // A warm bottle's helper goes once the game surely holds the bottle itself: dropping it earlier
            // would shut down the services the game is about to use.
            let elapsed = Date().timeIntervalSince(running.startedAt)
            if announced || running.exitCode != nil || elapsed > timing.handOverAfter {
                await context.warmer?.release(game)
            }
            if running.exitCode != nil { running.watchForIdle() }
            if !context.control.retrying {
                // Not judging any more: the game just runs; `finish` waits for its end.
                return nil
            }
            if let verdict = judge.observe(elapsed: elapsed, window: !owners.isEmpty, exitCode: running.exitCode,
                                           idle: running.isIdle) {
                return verdict
            }
            if let seconds = judge.held(at: elapsed).map({ Int($0) }), seconds != held {
                held = seconds
                context.events(.checking(held: seconds, needed: Int(timing.windowHolds.rounded(.up))))
            }
            do {
                try await Task.sleep(for: timing.poll)
            } catch {
                await running.stop()
                _ = await running.finish()
                throw error
            }
        }
    }

    private func record(_ id: GameID, duration: TimeInterval, working: GraphicsBackend?) throws {
        try GameLibrary.modify(paths.library) { $0.recordPlay(of: id, duration: duration, working: working) }
    }

    private func update(_ id: GameID, _ change: (inout GameRecord) -> Void) throws {
        try GameLibrary.modify(paths.library) { library in
            guard var game = library[id] else { return }
            change(&game)
            library[id] = game
        }
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

/// The lines a log gained since the last look.
final class LogTail {
    private let url: URL
    private var offset: UInt64 = 0
    private var partial = ""

    init(_ url: URL) { self.url = url }

    func newLines() -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else {
            return []
        }
        offset += UInt64(data.count)
        let text = partial + (String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? "")
        var lines = text.components(separatedBy: "\n")
        // The last piece may be a line still being written.
        partial = lines.removeLast()
        return lines
    }
}
