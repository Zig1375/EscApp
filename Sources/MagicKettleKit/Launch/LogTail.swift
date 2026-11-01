import Foundation

/// The lines a log gained since the last look.
final class LogTail {
    private let url: URL
    private var offset: UInt64 = 0
    private var partial = ""

    init(_ url: URL) { self.url = url }

    func newLines() -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else {
            return []
        }
        offset += UInt64(data.count)
        let text = partial + String(logBytes: data)
        var lines = text.components(separatedBy: "\n")
        // The last piece may be a line still being written.
        partial = lines.removeLast()
        return lines
    }
}

/// What the game's log says while an attempt is checked. An old game asking for its CD shows a message box and
/// waits: its window counts as the game's, so the request is caught from the log as it is written, not after the
/// game ends.
struct LogWatch {
    let tail: LogTail
    private var askedForDisc = false
    /// Chromium refused the game WebGL (`LogDiagnosis.refusesWebGL`).
    private(set) var noWebGL = false

    init(tail: LogTail) {
        self.tail = tail
    }

    mutating func read(events: (AutoLaunch.Event) -> Void) {
        let lines = tail.newLines()
        if !askedForDisc, let line = lines.first(where: LogDiagnosis.asksForDisc) {
            askedForDisc = true
            events(.asksForDisc(LogDiagnosis.messageText(line)))
        }
        noWebGL = noWebGL || lines.contains(where: LogDiagnosis.refusesWebGL)
    }
}
