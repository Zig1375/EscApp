import Darwin
import Foundation

/// Wine's processes as macOS sees them. Wine puts the Windows program's path in each process's first argument
/// (`C:\Program Files (x86)\Steam\steam.exe`), and the bottle in its `WINEPREFIX`, so a store game can be told
/// from its store's client in the same bottle.
public enum WineProcesses {
    public struct Process: Sendable, Equatable {
        public var pid: pid_t
        /// The Mac executable: Wine's loader, inside the Wine tree that runs it.
        public var executable: String
        /// The Windows program.
        public var program: String
        /// Started with msync on (`WineEnvironment`).
        public var msync = false
        /// The Windows program's arguments.
        public var arguments: [String] = []
    }

    /// Every process running in `bottle`.
    public static func running(in bottle: URL) -> [Process] {
        let prefix = bottle.path(percentEncoded: false)
        let trimmed = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        return allPIDs().compactMap { pid in
            let process = GameWindows.procArguments(of: pid)
            guard let wanted = process.environment["WINEPREFIX"],
                  wanted == trimmed || wanted == trimmed + "/",
                  let executable = GameWindows.executablePath(of: pid) else { return nil }
            return Process(pid: pid, executable: executable, program: process.arguments.first ?? "",
                           msync: WineEnvironment.msyncIsOn(process.environment),
                           arguments: Array(process.arguments.dropFirst()))
        }
    }

    /// Processes in `bottle` started from a program in the Windows folder `folder`.
    public static func game(in bottle: URL, folder: String) -> [pid_t] {
        running(in: bottle).filter { runs($0.program, from: folder) }.map(\.pid)
    }

    /// Whether the Windows program `program` is inside `folder`, compared as Windows does: without case, with
    /// either slash.
    static func runs(_ program: String, from folder: String) -> Bool {
        func normalized(_ path: String) -> String {
            path.replacingOccurrences(of: "/", with: "\\").lowercased()
        }
        let base = normalized(folder)
        let prefix = base.hasSuffix("\\") ? base : base + "\\"
        return normalized(program).hasPrefix(prefix)
    }

    /// The Wine tree a process runs from: its loader is `<tree>/bin/…` or `<tree>/lib/…`.
    static func wineTree(of executable: String) -> URL? {
        let parts = executable.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = parts.lastIndex(where: { $0 == "bin" || $0 == "lib" }), index > 0 else { return nil }
        return URL(filePath: parts[..<index].joined(separator: "/"), directoryHint: .isDirectory)
    }

    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(found, 0)))).filter { $0 > 0 }
    }
}

extension WindowsPath {
    /// The path a Mac folder has inside `bottle`: `drive_c/…` is `C:\…`, anything else is on `Z:`, which Wine
    /// maps to the Mac's `/`.
    public static func windowsPath(of url: URL, inBottle bottle: URL) -> String {
        let drive = bottle.appending(path: "drive_c", directoryHint: .isDirectory).resolvingSymlinksInPath()
        let resolved = url.resolvingSymlinksInPath()
        if let path = windowsPath(of: resolved, under: drive, drive: "C") { return path }
        return windowsPath(of: resolved, under: URL(filePath: "/", directoryHint: .isDirectory), drive: "Z") ?? ""
    }
}
