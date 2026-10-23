import CoreGraphics
import Darwin
import Foundation

/// Finds a running game's windows: windows of processes that run Wine from inside the game's Wine folder.
///
/// The launch loop uses this to tell a game that started from one that didn't, and the app to bring the game
/// forward (from macOS 14 an app started by another one can't take the front by itself).
public enum GameWindows {
    /// Processes of the game's session that have a window on screen, frontmost first.
    public static func owners(of session: GameSession) -> [pid_t] {
        owners(under: session.wineRoot, prefix: session.environment["WINEPREFIX"])
    }

    /// Processes running Wine from inside `root`, and in the bottle `prefix` when given, that have a window on
    /// screen. Every game on one runtime runs the same Wine, so the folder alone can't tell two games apart:
    /// with two running, a crash in one looked like a window in the other.
    public static func owners(under root: URL, prefix: String? = nil) -> [pid_t] {
        let rootPath = root.resolvingSymlinksInPath().path(percentEncoded: false)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [pid_t] = []
        var checked: Set<pid_t> = []
        for window in windows {
            // Normal windows, and the shielding level Wine puts a fullscreen game at; not menu bar items.
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 || layer >= 1000,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, checked.insert(pid).inserted,
                  let path = executablePath(of: pid), path.hasPrefix(rootPath) else { continue }
            if let prefix, environment(of: pid)["WINEPREFIX"] != prefix { continue }
            result.append(pid)
        }
        return result
    }

    /// Another process's environment, from `KERN_PROCARGS2` (readable for the user's own processes): an int
    /// with the argument count, the executable path, the arguments, then the environment, all NUL-separated.
    static func environment(of pid: pid_t) -> [String: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [:] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [:] }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    static func parseProcArgs(_ bytes: [UInt8]) -> [String: String] {
        guard bytes.count > MemoryLayout<Int32>.size else { return [:] }
        let argc = bytes.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        let strings = bytes.dropFirst(4).split(separator: 0, omittingEmptySubsequences: true)
            .map { String(bytes: $0, encoding: .utf8) ?? "" }
        // The executable path, then argc arguments, then the environment.
        var result: [String: String] = [:]
        for entry in strings.dropFirst(1 + argc) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            result[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return result
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return URL(filePath: path).resolvingSymlinksInPath().path(percentEncoded: false)
    }
}
