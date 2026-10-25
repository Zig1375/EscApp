import Foundation

/// Keeps a game's or store's logs folder small: the newest few logs of each kind. A kind is the name before its
/// timestamp: `2026-10-25_14-03-11.log` is a run, `install-…` an installer, `steam-update-…` a store's update.
/// Sorting them all together let installs, whose names sort after the dates, push out every run's log.
public enum LogRotation {
    /// Logs of each kind kept. The game's page reads its recent runs back from them (`LaunchHistory`).
    public static let kept = 3

    /// Removes all but the newest `keep` logs of each kind in `folder`.
    public static func prune(_ folder: URL, keep: Int = kept) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".log") }
        for name in stale(names, keep: keep) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    /// The names `prune` removes; the timestamps sort as text, oldest first.
    static func stale(_ names: [String], keep: Int) -> [String] {
        Dictionary(grouping: names, by: kind).values.flatMap { $0.sorted().dropLast(max(keep, 0)) }
    }

    /// `install-2026-10-25_14-03-11.log` → `install-`; a run's log has no prefix.
    static func kind(_ name: String) -> String {
        String(name.prefix { !$0.isNumber })
    }
}
