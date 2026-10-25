import Foundation

/// Past runs of a game, read back from the `[EscApp]` lines `GameLauncher` writes into each log.
public enum LaunchHistory {
    public struct Run: Sendable, Equatable {
        public var startedAt: Date
        public var backend: GraphicsBackend?
        /// Nil while the game is still running, or if EscApp quit before it ended.
        public var exitCode: Int32?
        public var processSeconds: Int?
        public var sessionSeconds: Int?
        public var log: URL

        public var worked: Bool? {
            guard let exitCode else { return nil }
            return exitCode == 0 || (processSeconds ?? 0) >= Int(GameLauncher.workingAfter)
        }
    }

    /// Newest first.
    public static func runs(in folder: URL) -> [Run] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".log") }.sorted(by: >).compactMap { name in
            let file = folder.appending(path: name)
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            // The header is at the top and the exit line at the end; game output in between can be huge.
            let head = (try? handle.read(upToCount: 4096)).map { String(logBytes: $0) } ?? ""
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 512 ? size - 512 : 0)
            let tail = (try? handle.readToEnd()).map { String(logBytes: $0) } ?? ""
            return parse(head: head, tail: tail, log: file)
        }
    }

    static func parse(head: String, tail: String, log: URL) -> Run? {
        func value(after prefix: String, in text: String) -> String? {
            text.components(separatedBy: "\n").first { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        }
        guard let launch = value(after: "[EscApp] Launch", in: head),
              let started = ISO8601DateFormatter().date(from: launch) else { return nil }
        var run = Run(startedAt: started, backend: value(after: "[EscApp] Backend", in: head)
                        .flatMap(GraphicsBackend.init(rawValue:)), log: log)
        // "[EscApp] Exit 0 after 17 s, bottle idle after 21 s"
        if let exit = value(after: "[EscApp] Exit", in: tail) {
            let numbers = exit.split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Int($0) }
            run.exitCode = numbers.first.map(Int32.init)
            run.processSeconds = numbers.dropFirst().first
            run.sessionSeconds = numbers.dropFirst(2).first
        }
        return run
    }
}
