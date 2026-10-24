import AppKit
import EscAppKit
import Foundation

/// A first launch on Auto (FirstRun.dc.html): EscApp tries the backends one after another while its own screen
/// covers the game's windows, so a failing attempt doesn't flash them open and shut. The game comes out once an
/// attempt works.
extension LibraryModel.Launch {
    struct Tuning: Equatable {
        /// One attempt that didn't work.
        struct Try: Equatable {
            var backend: GraphicsBackend
            var seconds: Int
            var reason: AttemptJudge.Failure?
            var problem: LogDiagnosis.Problem?
        }

        var order: [GraphicsBackend]
        var failed: [Try] = []
        /// The attempt running now, from 0.
        var current = 0
        /// The process whose window is up in this attempt, hidden under EscApp's screen.
        var windowOwner: Int32?
        /// "checking 12 of 15 s".
        var held: Int?
        var needed = Int(AttemptJudge.windowHolds)

        var currentBackend: GraphicsBackend { order[min(current, order.count - 1)] }
    }
}

extension LibraryModel {
    /// Takes the launch events that change the settings screen. False for the rest, and for a launch that
    /// isn't looking for settings.
    func handleTuning(_ event: AutoLaunch.Event, for id: GameID) -> Bool {
        if case let .tuning(order) = event {
            guard launch?.id == id else { return true }
            launch?.tuning = .init(order: order)
            NSApp.activate()
            return true
        }
        guard launch?.id == id, var tuning = launch?.tuning else { return false }
        switch event {
        case let .started(session, _, attempt, _):
            sessions[id] = session
            tuning.current = attempt - 1
            tuning.windowOwner = nil
            tuning.held = nil
        case let .windowShown(pid):
            // EscApp stays in front: a game that grabs the mouse would otherwise keep it from the buttons.
            tuning.windowOwner = pid
            NSApp.activate()
        case let .checking(held, needed):
            tuning.held = held
            tuning.needed = needed
        case let .retrying(failed, _, _, _):
            tuning.failed.append(.init(backend: failed.backend, seconds: failed.seconds, reason: failed.failure,
                                       problem: failed.diagnosis.problem))
        case let .working(backend, learned):
            tuningWorked(tuning, backend: backend, learned: learned, for: id)
            return true
        case .preparing, .tuning, .asksForDisc:
            // Getting ready updates the steps as usual; the CD request ends the screen there.
            return false
        }
        launch?.tuning = tuning
        return true
    }

    /// The cover goes and the game, which has been running under it, comes to the front.
    private func tuningWorked(_ tuning: Launch.Tuning, backend: GraphicsBackend, learned: Bool, for id: GameID) {
        launch = nil
        states[id] = .running(since: Date())
        if let pid = tuning.windowOwner { GameWindows.bringForward(pid) }
        if learned, let game = game(id) { self.learned = Learned(id: id, name: game.name, backend: backend) }
    }

    /// "Choose Settings Myself": the check stops, the game closes, and its Advanced settings open.
    func chooseSettingsMyself() {
        guard let id = launch?.id else { return }
        cancelLaunch()
        shownPage = .advanced(id)
        NSApp.activate()
        NSApp.windows.first { $0.identifier?.rawValue == "library" }?.makeKeyAndOrderFront(nil)
    }
}
