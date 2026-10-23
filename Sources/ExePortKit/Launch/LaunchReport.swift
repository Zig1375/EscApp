import Foundation

/// "Copy report" after a game didn't start: plain text for an issue or a forum post. Only what the launch saw:
/// the game, the attempts, and the error lines of the last log. Nothing is sent anywhere by ExePort.
public enum LaunchReport {
    public static func text(_ result: AutoLaunch.Result, runtime: String, macOS: String, app: String) -> String {
        var lines = [
            "ExePort \(app), macOS \(macOS), runtime \(runtime)",
            "Game: \(result.game.name)",
            "Executable: \(URL(filePath: result.game.executable).lastPathComponent)",
            "Windows: \(result.game.windowsVersion.displayName)",
            "",
            "Attempts:",
        ]
        for attempt in result.attempts {
            let outcome: String = switch attempt.failure {
            case nil: "worked"
            case let .closed(code)?: "closed after \(attempt.seconds) s, exit code \(code)"
            case .noWindow?: "no window after \(attempt.seconds) s"
            }
            lines.append("- \(attempt.backend.displayName): \(outcome)")
            if let evidence = attempt.diagnosis.evidence { lines.append("  \(evidence)") }
        }
        if let last = result.attempts.last, !last.diagnosis.excerpt.isEmpty {
            lines += ["", "Last log, errors only:"] + last.diagnosis.excerpt
        }
        // Paths name the user's home folder; the report doesn't need them.
        var home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        if home.hasSuffix("/") { home.removeLast() }
        return lines.joined(separator: "\n").replacingOccurrences(of: home, with: "~")
    }
}
