import Foundation
import Synchronization

/// A game that `GameLauncher.start` started: what the launch loop watches while it decides whether the attempt
/// works, and waits on until the bottle is idle.
public final class RunningGame: Sendable {
    public let prepared: GameLauncher.Prepared
    public let session: GameSession
    public let startedAt: Date
    let process: ProcessExit
    private let idle = Mutex<Bool?>(nil)
    private let pruneLogs: @Sendable (GameID) -> Void

    init(prepared: GameLauncher.Prepared, session: GameSession, startedAt: Date, process: ProcessExit,
         pruneLogs: @escaping @Sendable (GameID) -> Void) {
        self.prepared = prepared
        self.session = session
        self.startedAt = startedAt
        self.process = process
        self.pruneLogs = pruneLogs
    }

    /// The game's process's exit code, once it exited.
    public var exitCode: Int32? { process.code }
    /// Whether everything in the bottle has stopped. Known only after `watchForIdle`.
    public var isIdle: Bool { idle.withLock { $0 == true } }

    /// Once the game's process exited, starts waiting for the bottle's server in the background. Waiting before
    /// that would start a server of its own.
    public func watchForIdle() {
        let start = idle.withLock { idle in
            guard process.code != nil, idle == nil else { return false }
            idle = false
            return true
        }
        guard start else { return }
        Task {
            if prepared.gameFolder == nil { await waitForServer() }
            idle.withLock { $0 = true }
        }
    }

    /// Waits until everything in the bottle has exited, writes the log's last line, and says how it went.
    public func finish() async -> GameLauncher.Outcome {
        let exitCode = await process.wait()
        let processDuration = (process.exitedAt ?? Date()).timeIntervalSince(startedAt)
        // The game may live on after `wine` returns (launchers); it's over when the bottle's server is. A store
        // game's bottle keeps its client running: its own processes ending was the end.
        if prepared.gameFolder == nil { await waitForServer() }
        idle.withLock { $0 = true }

        let duration = Date().timeIntervalSince(startedAt)
        let footer = "[Plaviox] Exit \(exitCode) after \(Int(processDuration)) s, bottle idle after \(Int(duration)) s"
        if let log = try? FileHandle(forWritingTo: prepared.log) {
            _ = try? log.seekToEnd()
            log.write(Data((footer + "\n").utf8))
            try? log.close()
        }
        pruneLogs(prepared.game.id)
        return GameLauncher.Outcome(exitCode: exitCode, duration: duration, processDuration: processDuration,
                                    backend: prepared.backend, log: prepared.log)
    }

    private func waitForServer() async {
        _ = try? await ProcessRunner.run(prepared.wine.wineserver.path, ["-w"], environment: prepared.environment)
    }
}

/// The exit of the game's `wine` process, filled in by `Process.terminationHandler`.
final class ProcessExit: Sendable {
    private let state = Mutex<(code: Int32, at: Date)?>(nil)
    private let stream: AsyncStream<Int32>
    private let continuation: AsyncStream<Int32>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    var code: Int32? { state.withLock { $0?.code } }
    var exitedAt: Date? { state.withLock { $0?.at } }

    func exited(_ code: Int32) {
        state.withLock { $0 = (code, Date()) }
        continuation.yield(code)
        continuation.finish()
    }

    func wait() async -> Int32 {
        for await code in stream { return code }
        return code ?? -1
    }
}
