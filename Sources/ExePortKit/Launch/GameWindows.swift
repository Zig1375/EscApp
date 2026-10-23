import CoreGraphics
import Darwin
import Foundation

/// Finds a running game's windows: windows of processes that run Wine from inside the game's Wine folder.
///
/// The launch loop uses this to tell a game that started from one that didn't, and the app to bring the game
/// forward (from macOS 14 an app started by another one can't take the front by itself).
public enum GameWindows {
    /// Processes running Wine from inside `root` that have a window on screen, frontmost first.
    public static func owners(under root: URL) -> [pid_t] {
        let prefix = root.resolvingSymlinksInPath().path(percentEncoded: false)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [pid_t] = []
        for window in windows {
            // Normal windows, and the shielding level Wine puts a fullscreen game at; not menu bar items.
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 || layer >= 1000,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, !result.contains(pid),
                  let path = executablePath(of: pid), path.hasPrefix(prefix) else { continue }
            result.append(pid)
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
