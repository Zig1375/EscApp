import AppKit
import Darwin

/// Finds a running game's windows and brings them forward.
///
/// Wine starts the game as its own macOS app, and from macOS 14 an app started by another one can't take the
/// front by itself unless that one yields it. Without this the game's window opened behind ExePort, and the
/// player saw nothing while the game was already running.
enum GameWindows {
    /// Processes running Wine from inside `root` that have a normal window on screen.
    static func owners(under root: URL) -> [pid_t] {
        let prefix = root.resolvingSymlinksInPath().path(percentEncoded: false)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [pid_t] = []
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, !result.contains(pid),
                  let path = executablePath(of: pid), path.hasPrefix(prefix) else { continue }
            result.append(pid)
        }
        return result
    }

    /// Lets the game's process come to the front, and asks it to.
    @MainActor
    static func bringForward(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return URL(filePath: path).resolvingSymlinksInPath().path(percentEncoded: false)
    }
}
