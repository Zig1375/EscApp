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
        owners(under: session.wineRoot, prefix: session.environment["WINEPREFIX"], folder: session.gameFolder)
    }

    /// Processes running Wine from inside `root`, and in the bottle `prefix` when given, that have a window on
    /// screen. Every game on one runtime runs the same Wine, so the folder alone can't tell two games apart:
    /// with two running, a crash in one looked like a window in the other.
    /// - Parameter folder: only processes started from this Windows folder (`C:\…\Portal 2`).
    public static func owners(under root: URL, prefix: String? = nil, folder: String? = nil) -> [pid_t] {
        let rootPath = root.resolvingSymlinksInPath().path(percentEncoded: false)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [pid_t] = []
        var checked: Set<pid_t> = []
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, isGameLayer(layer),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, checked.insert(pid).inserted,
                  let path = executablePath(of: pid), path.hasPrefix(rootPath) else { continue }
            if prefix != nil || folder != nil {
                let process = procArguments(of: pid)
                if let prefix, process.environment["WINEPREFIX"] != prefix { continue }
                // A store game's bottle also holds the store's client, whose windows aren't the game's.
                if let folder, !WineProcesses.runs(process.arguments.first ?? "", from: folder) { continue }
            }
            result.append(pid)
        }
        return result
    }

    /// Window levels a game's window can have: normal ones, "always on top" ones (21: Wine's level for a
    /// `WS_EX_TOPMOST` window, which full-screen games use) and the shielding level of a captured display. Not the
    /// menu bar's (24) or its status items' (25), where a Wine program's tray icon would be.
    static func isGameLayer(_ layer: Int) -> Bool {
        (0..<24).contains(layer) || layer >= 1000
    }

    /// The game's own size, from the largest window of its session on screen (`GameScaling.learn`).
    public static func learnWindow(of session: GameSession) -> GameScaling.LearnedWindow? {
        let owners = Set(owners(of: session))
        guard !owners.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        let frames = windows.compactMap { window -> CGRect? in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, owners.contains(pid),
                  let layer = window[kCGWindowLayer as String] as? Int, isGameLayer(layer),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }
        guard let largest = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        let display = CGDisplayBounds(CGMainDisplayID())
        return GameScaling.learn(frame: largest, display: display, scale: session.scale)
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
        parseProcArguments(bytes).environment
    }

    /// The arguments and the environment from `KERN_PROCARGS2` bytes.
    static func parseProcArguments(_ bytes: [UInt8]) -> (arguments: [String], environment: [String: String]) {
        guard bytes.count > MemoryLayout<Int32>.size else { return ([], [:]) }
        let argc = bytes.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        let strings = bytes.dropFirst(4).split(separator: 0, omittingEmptySubsequences: true)
            .map { String(bytes: $0, encoding: .utf8) ?? "" }
        // The executable path, then argc arguments, then the environment.
        var result: [String: String] = [:]
        for entry in strings.dropFirst(1 + argc) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            result[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return (Array(strings.dropFirst().prefix(argc)), result)
    }

    static func procArguments(of pid: pid_t) -> (arguments: [String], environment: [String: String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return ([], [:]) }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return ([], [:]) }
        return parseProcArguments(Array(buffer.prefix(size)))
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return URL(filePath: path).resolvingSymlinksInPath().path(percentEncoded: false)
    }
}
