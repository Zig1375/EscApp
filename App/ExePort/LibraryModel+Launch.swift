import AppKit
import ExePortKit
import Foundation

/// Starting a game (Launching.dc.html): the "getting ready" steps, the retry with the next backend when the game
/// fails at start, what was learned, and what to say when nothing worked.
extension LibraryModel {
    /// The launch sheet. One sheet for the whole launch, so going from getting ready to retrying to failed only
    /// changes what it shows.
    struct Launch: Identifiable, Equatable {
        enum StepState: Equatable { case waiting, active, done }

        enum Phase: Equatable {
            case preparing
            case retrying(Retry)
            case failed(Failure)
        }

        /// "DXVK doesn't seem to suit this game. Starting with WineD3D (attempt 2 of 3)".
        struct Retry: Equatable {
            var failed: GraphicsBackend
            var next: GraphicsBackend
            var attempt: Int
            var total: Int
            var seconds: Int
            var reason: AttemptJudge.Failure?
            var log: URL
        }

        /// "Nothing helped": the most telling reason, and the report to copy.
        struct Failure: Equatable {
            var problem: LogDiagnosis.Problem?
            var reason: AttemptJudge.Failure?
            var tried: [GraphicsBackend]
            var report: String
        }

        let id: GameID
        let name: String
        let firstTime: Bool
        var phase: Phase = .preparing
        var windows: WindowsVersion?
        var windowsFirstTime = false
        var windowsState: StepState = .active
        var graphics: String?
        var startState: StepState = .waiting
        /// Set after a while without a game window, to say that this can take a minute.
        var slow = false

        var isFailed: Bool { if case .failed = phase { true } else { false } }
    }

    struct Learned: Identifiable, Equatable {
        let id: GameID
        let name: String
        let backend: GraphicsBackend
    }

    func play(_ game: GameRecord) {
        guard states[game.id] == nil else { return }
        states[game.id] = .starting
        launch = Launch(id: game.id, name: game.name, firstTime: (game.launches ?? 0) == 0)
        let control = LaunchControl()
        launchControl = control
        let paths = paths
        launchTasks[game.id] = Task {
            defer {
                states[game.id] = nil
                sessions[game.id] = nil
                launchTasks[game.id] = nil
                if launch?.id == game.id, launch?.isFailed == false { launch = nil }
                reload()
            }
            do {
                guard let (runtime, knownGames) = try currentRuntime() else {
                    notice = Notice(title: String(localized: "Components aren't installed"),
                                    message: String(localized: "Open Settings → Components to install them."))
                    return
                }
                let result = try await AutoLaunch(paths: paths).play(
                    game, runtime: runtime, knownGames: knownGames, control: control) { event in
                    Task { @MainActor in self.handle(event, for: game.id) }
                }
                if result.working == nil, let last = result.attempts.last, last.failure != nil {
                    showFailure(result, runtime: runtime)
                }
            } catch is CancellationError {
                // The player pressed Cancel.
            } catch {
                launch = nil
                notice = Notice(title: String(localized: "\(game.name) can't start"),
                                message: String(describing: error))
            }
        }
    }

    /// "Cancel" in the launch sheet: stop whatever has started and forget the launch.
    func cancelLaunch() {
        guard let current = launch else { return }
        launch = nil
        if current.isFailed { return }
        launchTasks[current.id]?.cancel()
        if let session = sessions[current.id] { Task { await session.stop() } }
    }

    /// "Don't Retry": the attempt that is starting runs on as it is, without being judged or replaced.
    func stopRetrying() {
        launchControl?.stopRetrying()
        launch = nil
    }

    func copyReport(_ failure: Launch.Failure) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(failure.report, forType: .string)
    }

    func showFolder(of id: GameID) {
        guard let game = game(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: game.executable)])
    }

    private func handle(_ event: AutoLaunch.Event, for id: GameID) {
        switch event {
        case let .preparing(step):
            apply(step, to: id)
        case let .started(session, _, attempt, _):
            sessions[id] = session
            if attempt == 1 { markSlow(id) }
        case let .windowShown(pid):
            states[id] = .running(since: Date())
            if launch?.id == id { launch = nil }
            GameWindows.bringForward(pid)
        case let .working(backend, learned):
            if learned, let game = game(id) { self.learned = Learned(id: id, name: game.name, backend: backend) }
        case let .retrying(failed, next, attempt, total):
            states[id] = .starting
            guard let game = game(id) else { return }
            var current = launch?.id == id ? launch : nil
            current = current ?? Launch(id: id, name: game.name, firstTime: false)
            current?.phase = .retrying(.init(failed: failed.backend, next: next, attempt: attempt, total: total,
                                              seconds: failed.seconds, reason: failed.failure, log: failed.log))
            launch = current
            // The game's window had the front; the retry is shown in ExePort's.
            NSApp.activate()
        }
    }

    private func showFailure(_ result: AutoLaunch.Result, runtime: RuntimeManifest.Runtime) {
        guard let last = result.attempts.last else { return }
        // The most telling reason: one that rules the game out beats a crash on the last backend tried.
        let problem = result.attempts.compactMap(\.diagnosis.problem).first { !LogDiagnosis.retryHelps($0) }
            ?? last.diagnosis.problem
        let report = LaunchReport.text(result, runtime: runtime.id, macOS: Version.thisMac.description,
                                       app: Version.thisApp.description)
        launch = Launch(id: result.game.id, name: result.game.name, firstTime: false,
                        phase: .failed(.init(problem: problem, reason: last.failure,
                                             tried: result.attempts.map(\.backend), report: report)))
        NSApp.activate()
    }

    private func apply(_ step: GameLauncher.Step, to id: GameID) {
        guard var current = launch, current.id == id, current.phase == .preparing else { return }
        switch step {
        case let .windows(version, firstTime):
            current.windows = version
            current.windowsFirstTime = firstTime
            current.windowsState = .active
        case let .graphics(backend, directX):
            current.windowsState = .done
            let api: String? = switch directX {
            case .legacy?: "DirectDraw"
            case .d3d9?: "DirectX 9"
            case .d3d11?: "DirectX 11"
            case .d3d12?: "DirectX 12"
            case nil: nil
            }
            current.graphics = api.map { "\(backend.displayName) (\($0))" } ?? backend.displayName
        case .starting:
            current.startState = .active
        }
        launch = current
    }

    /// Says so when the window takes long: Wine's first start under Rosetta can need most of a minute.
    private func markSlow(_ id: GameID) {
        Task {
            try? await Task.sleep(for: .seconds(15))
            if launch?.id == id, launch?.phase == .preparing, states[id] == .starting { launch?.slow = true }
        }
    }
}
