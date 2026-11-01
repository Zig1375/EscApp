import CryptoKit
import Foundation

/// Disc images `hdiutil` can't attach: BIN/CUE and other copies of a CD's raw sectors (`.img` from CloneCD,
/// `.mdf` from Alcohol). A raw sector is 2352 bytes: sync and header, then the 2048 bytes of data, then error
/// correction. Plaviox copies the data out of the CD's data track into a plain ISO, kept next to the attached
/// discs and made again only when the image changes.
///
/// CD audio tracks (many old games play their music from them) are left out: an ISO can't hold them, so such a
/// game runs, but without that music.
public enum RawDisc {
    public static let extensions: Set<String> = ["cue", "bin", "img", "mdf"]

    /// What a track's sectors hold, from a cue sheet's `TRACK nn MODE1/2352`.
    public struct Track: Sendable, Equatable {
        public var file: String
        /// Bytes per sector in the file.
        public var sectorSize: Int
        /// Where a sector's 2048 bytes of data start: 16 after MODE1's header, 24 after MODE2's subheader.
        public var dataOffset: Int
        /// The track's first sector in its file.
        public var start: Int
        /// The next track's first sector in the same file, when there is one.
        public var end: Int?
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noDataTrack
        case unreadable(String)

        public var description: String {
            switch self {
            case .noDataTrack: "This disc image holds only music, no game data."
            case let .unreadable(name): "Couldn't read the disc image \(name)."
            }
        }
    }

    /// Whether `file` is raw sectors: a cue sheet, or a file starting with a CD's sync pattern.
    public static func isRaw(_ file: URL) -> Bool {
        let ext = file.pathExtension.lowercased()
        if ext == "cue" { return true }
        guard extensions.contains(ext), let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 12)).map(isSync) ?? false
    }

    static let sync = Data([0x00] + Array(repeating: 0xFF, count: 10) + [0x00])
    static func isSync(_ bytes: Data) -> Bool { bytes.prefix(12) == sync }

    /// The data track of a cue sheet. `INDEX 01 mm:ss:ff` gives where each track starts (75 sectors a second);
    /// a track ends where the next one in the same file starts.
    static func dataTrack(cue text: String) -> Track? {
        var file = ""
        struct Entry {
            var file: String
            var mode: String
            var start: Int?
        }
        var entries: [Entry] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            switch words.first?.uppercased() {
            case "FILE"?:
                if let open = line.firstIndex(of: "\""),
                   let close = line[line.index(after: open)...].firstIndex(of: "\"") {
                    file = String(line[line.index(after: open)..<close])
                } else if words.count >= 2 {
                    file = words[1]
                }
            case "TRACK"? where words.count >= 3:
                entries.append(Entry(file: file, mode: words[2].uppercased()))
            case "INDEX"? where words.count >= 3 && words[1] == "01" && !entries.isEmpty:
                let parts = words[2].split(separator: ":").compactMap { Int($0) }
                if parts.count == 3 { entries[entries.count - 1].start = (parts[0] * 60 + parts[1]) * 75 + parts[2] }
            default:
                continue
            }
        }
        for (index, entry) in entries.enumerated() {
            guard let layout = layout(of: entry.mode) else { continue }
            let next = entries.dropFirst(index + 1).first { $0.file == entry.file }
            return Track(file: entry.file, sectorSize: layout.sectorSize, dataOffset: layout.offset,
                         start: entry.start ?? 0, end: next?.start)
        }
        return nil
    }

    /// Sector layout of a track mode; nil for audio.
    static func layout(of mode: String) -> (sectorSize: Int, offset: Int)? {
        switch mode {
        case "MODE1/2048": (2048, 0)
        case "MODE1/2352": (2352, 16)
        case "MODE2/2336": (2336, 8)
        case "MODE2/2352": (2352, 24)
        default: nil
        }
    }

    /// The ISO Plaviox attaches for `image`, made the first time. Named by the image's path, size and date, so a
    /// changed image is converted again.
    public static func iso(for image: URL, paths: AppPaths) throws -> URL {
        let output = cachedISO(for: image, paths: paths)
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let track = try track(of: image)
        let source = image.pathExtension.lowercased() == "cue"
            ? image.deletingLastPathComponent().appending(path: track.file) : image
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let partial = output.appendingPathExtension("part")
        do {
            try copyData(of: track, from: source, to: partial)
            try FileManager.default.moveItem(at: partial, to: output)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        return output
    }

    static func cachedISO(for image: URL, paths: AppPaths) -> URL {
        let values = try? image.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(image.standardizedFileURL.path)|\(values?.fileSize ?? 0)|"
            + "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let name = image.deletingPathExtension().lastPathComponent
        return paths.root.appending(path: "Discs/Converted/\(name)-\(hash).iso")
    }

    private static func track(of image: URL) throws -> Track {
        if image.pathExtension.lowercased() == "cue" {
            guard let data = try? Data(contentsOf: image),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            else { throw Failure.unreadable(image.lastPathComponent) }
            guard let track = dataTrack(cue: text) else { throw Failure.noDataTrack }
            return track
        }
        // Without a cue sheet: a raw image starts with its data track, MODE1 unless the header's mode byte says 2.
        guard let handle = try? FileHandle(forReadingFrom: image), let header = try? handle.read(upToCount: 16)
        else { throw Failure.unreadable(image.lastPathComponent) }
        try? handle.close()
        let mode2 = header.count == 16 && header[header.startIndex + 15] == 2
        return Track(file: image.lastPathComponent, sectorSize: 2352, dataOffset: mode2 ? 24 : 16, start: 0)
    }

    private static func copyData(of track: Track, from source: URL, to output: URL) throws {
        guard let input = try? FileHandle(forReadingFrom: source) else {
            throw Failure.unreadable(source.lastPathComponent)
        }
        defer { try? input.close() }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        try input.seek(toOffset: UInt64(track.start * track.sectorSize))
        var remaining = track.end.map { $0 - track.start } ?? Int.max
        let batch = 512
        while remaining > 0 {
            let count = min(batch, remaining)
            guard let chunk = try input.read(upToCount: count * track.sectorSize), !chunk.isEmpty else { break }
            var data = Data(capacity: chunk.count / track.sectorSize * 2048)
            var offset = chunk.startIndex
            while offset + track.dataOffset + 2048 <= chunk.endIndex {
                data.append(chunk[(offset + track.dataOffset)..<(offset + track.dataOffset + 2048)])
                offset += track.sectorSize
            }
            try writer.write(contentsOf: data)
            remaining -= chunk.count / track.sectorSize
            if chunk.count < count * track.sectorSize { break }
        }
    }
}
