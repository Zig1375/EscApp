import Foundation

/// "Copy report" after a game didn't start: plain text for an issue or a forum post. Only what the launch saw:
/// the game, the attempts, and the error lines of the last log. Nothing is sent anywhere by EscApp.
public enum LaunchReport {
    public static func text(_ result: AutoLaunch.Result, runtime: String, macOS: String, app: String,
                            system: SystemInfo = .current) -> String {
        var lines = [
            "EscApp \(app), macOS \(macOS), runtime \(runtime)",
            "Mac: \(system.summary)",
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
            case .blankPicture?: "its window stayed blank"
            case .frozen?: "its picture froze on a blank window"
            case .noWebGL?: "its graphics didn't start (WebGL refused)"
            }
            lines.append("- \(attempt.backend.displayName): \(outcome)")
            if let evidence = attempt.diagnosis.evidence { lines.append("  \(evidence)") }
        }
        if let last = result.attempts.last, !last.diagnosis.excerpt.isEmpty {
            lines += ["", "Last log, errors only:"] + last.diagnosis.excerpt
        }
        return withoutHome(lines)
    }

    /// Advanced → "Copy Report": the same, from the game's last log instead of a launch that just happened.
    public static func text(game: GameRecord, log: URL, runtime: String, macOS: String, app: String,
                            system: SystemInfo = .current) -> String {
        let run = LaunchHistory.runs(in: log.deletingLastPathComponent()).first { $0.log == log }
        let diagnosis = LogDiagnosis(log: LogDiagnosis.read(log) ?? "")
        var lines = [
            "EscApp \(app), macOS \(macOS), runtime \(runtime)",
            "Mac: \(system.summary)",
            "Game: \(game.name)",
            "Executable: \(URL(filePath: game.executable).lastPathComponent)",
            "Windows: \(game.windowsVersion.displayName)",
            "",
            "Last run: \(run?.backend?.displayName ?? "?"), "
                + (run?.exitCode.map { "exit code \($0) after \(run?.processSeconds ?? 0) s" } ?? "didn't end"),
        ]
        if let evidence = diagnosis.evidence { lines.append(evidence) }
        if !diagnosis.excerpt.isEmpty { lines += ["", "Log, errors only:"] + diagnosis.excerpt }
        return withoutHome(lines)
    }

    /// Paths name the user's home folder; the report doesn't need them.
    private static func withoutHome(_ lines: [String]) -> String {
        var home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        if home.hasSuffix("/") { home.removeLast() }
        return lines.joined(separator: "\n").replacingOccurrences(of: home, with: "~")
    }
}
