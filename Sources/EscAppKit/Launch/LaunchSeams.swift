import Foundation

/// A started game as the launch loop sees it. `RunningGame` is the real one; tests script one, so the loop's
/// decisions (retry, give up, hand a warm bottle over) are checked without Wine.
public protocol GameAttempt: AnyObject, Sendable {
    var session: GameSession { get }
    var startedAt: Date { get }
    /// The attempt's log, read while the game runs.
    var log: URL { get }
    /// The game's process's exit code, once it exited.
    var exitCode: Int32? { get }
    /// Whether everything in the bottle has stopped. Known only after `watchForIdle`.
    var isIdle: Bool { get }
    func watchForIdle()
    /// Ends everything in the game's bottle.
    func stop() async
    /// Waits until everything in the bottle has exited.
    func finish() async -> GameLauncher.Outcome
}

/// Prepares and starts one attempt with one backend.
public protocol AttemptStarter: Sendable {
    func start(_ game: GameRecord, runtime: RuntimeManifest.Runtime, backend: GraphicsBackend, verboseLog: Bool,
               progress: @Sendable (GameLauncher.Step) -> Void) async throws -> any GameAttempt
}

/// What a launch does with warm bottles (`BottleWarmer`).
public protocol WarmBottles: Sendable {
    /// The game starting in its warm bottle takes it over.
    func release(_ id: GameID) async
    /// Other games' warm bottles go when a game starts: the game gets the memory.
    func coolAll(except kept: GameID?) async
}

extension GameLauncher: AttemptStarter {
    public func start(_ game: GameRecord, runtime: RuntimeManifest.Runtime, backend: GraphicsBackend,
                      verboseLog: Bool, progress: @Sendable (Step) -> Void) async throws -> any GameAttempt {
        let prepared = try await prepare(game, runtime: runtime, backend: backend, verboseLog: verboseLog,
                                         progress: progress)
        let running: RunningGame = try start(prepared)
        return running
    }
}

extension RunningGame: GameAttempt {
    public var log: URL { prepared.log }
    public func stop() async { await session.stop() }
}

extension BottleWarmer: WarmBottles {}

extension AutoLaunch {
    /// How long things may take. The standard values are for real games; tests shrink them.
    public struct Timing: Sendable {
        /// How often the loop looks at the game.
        public var poll: Duration = .milliseconds(100)
        public var windowHolds: TimeInterval = AttemptJudge.windowHolds
        public var firstWindowTimeout: TimeInterval = AttemptJudge.firstWindowTimeout
        /// A game still showing no window by then has connected to its warm bottle's Wine anyway.
        public var handOverAfter: TimeInterval = 10
        /// How often a Chromium program's window is looked at while it is checked (`WindowPicture`).
        public var pictureEvery: TimeInterval = 1
        /// How long a first launch of a Chromium program keeps looking after it counted as working: a launcher
        /// (Steam's updater) can draw, and the window that follows stay blank.
        public var lateWatch: TimeInterval = 180
        public var lateEvery: TimeInterval = 2
        /// How long a blank window with an idle game makes it frozen (`FrozenWindow`).
        public var frozenFor: TimeInterval = 10
        /// How long a store game being searched for may take to show a window: Steam restarted in another Wine
        /// tree took two minutes to start Among Us, and on one it couldn't run it never did.
        public var storeWindowTimeout: TimeInterval = 240

        public static let standard = Timing()
    }
}
