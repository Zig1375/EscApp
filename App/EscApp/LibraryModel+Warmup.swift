import AppKit
import EscAppKit

/// Follows `WarmPolicy`: warms while EscApp is in front, cools a few seconds after it loses focus. A game's
/// launch cools the other bottles itself (`AutoLaunch`).
extension LibraryModel {
    func watchFocus() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                self.coolTask?.cancel()
                self.warmLastPlayed()
            }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.coolSoon() }
        }
        if NSApp.isActive { warmLastPlayed() }
    }

    /// The pointer is on a game's card: warm it if it stays there a moment, so a pass across the library
    /// doesn't start Wine for every game it crosses.
    func hovering(_ game: GameRecord, _ isHovering: Bool) {
        hoverTask?.cancel()
        guard isHovering else { return }
        hoverTask = Task {
            try? await Task.sleep(for: WarmPolicy.hoverDelay)
            guard !Task.isCancelled else { return }
            warmUp(game)
        }
    }

    func warmUp(_ game: GameRecord) {
        guard WarmPolicy.mayWarm(ready: isReady, appActive: NSApp.isActive, gamesRunning: !states.isEmpty),
              let (runtime, _) = try? currentRuntime() else { return }
        Task { await warmer.warm(game, runtime: runtime) }
    }

    private func warmLastPlayed() {
        if let game = WarmPolicy.lastPlayed(games) { warmUp(game) }
    }

    private func coolSoon() {
        coolTask?.cancel()
        coolTask = Task {
            try? await Task.sleep(for: WarmPolicy.coolAfterFocusLoss)
            guard !Task.isCancelled, !NSApp.isActive else { return }
            await warmer.coolAll()
        }
    }
}
