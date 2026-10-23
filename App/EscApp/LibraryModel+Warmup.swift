import AppKit
import EscAppKit

/// When bottles are warm (`BottleWarmer`): only while EscApp is in front and no game runs, for the last played
/// game and the card under the pointer. Five seconds after EscApp loses focus they all go, and so do all but
/// the game's own when a game starts. Macs with less than 16 GB don't warm at all.
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
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            warmUp(game)
        }
    }

    func warmUp(_ game: GameRecord) {
        guard BottleWarmer.isAllowed, isReady, NSApp.isActive, states.isEmpty,
              let (runtime, _) = try? currentRuntime() else { return }
        Task { await warmer.warm(game, runtime: runtime) }
    }

    private func warmLastPlayed() {
        let played = games.compactMap { game in game.lastPlayed.map { (game, $0) } }
        if let (game, _) = played.max(by: { $0.1 < $1.1 }) { warmUp(game) }
    }

    private func coolSoon() {
        coolTask?.cancel()
        coolTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, !NSApp.isActive else { return }
            await warmer.coolAll()
        }
    }
}
