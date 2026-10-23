import AppKit
import EscAppKit

extension GameWindows {
    /// Lets the game's process come to the front, and asks it to. Without this the game's window opened behind
    /// EscApp, and the player saw nothing while the game was already running.
    @MainActor
    static func bringForward(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }
}
