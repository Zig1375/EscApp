import Compression
import Foundation

/// The scripts of an RPG Maker XP/VX/VX Ace game, read to learn the size of its window before the first launch.
///
/// EscApp enlarges a small window by the system DPI, which has to be set before the game starts, so it used the
/// size it saw last time: a first launch came up at half the size of every later one ("Let's Do The Goodfeeling
/// Wife! RPG", 1× and then 2×). RPG Maker's size is the engine's default unless a script calls
/// `Graphics.resize_screen`, and that game's scripts do (640×480 instead of VX's 544×416).
///
/// Games ship their data in one archive (`Game.rgssad`, `.rgss2a`, `.rgss3a`) that Enterbrain's engine reads
/// with a fixed XOR scheme; only the scripts file is taken out of it, and nothing in it is run.
enum RGSSArchive {
    static let names = ["Game.rgssad", "Game.rgss2a", "Game.rgss3a"]
    static let scriptFiles = ["Scripts.rxdata", "Scripts.rvdata", "Scripts.rvdata2"]

    /// The game's scripts: `Data/Scripts.*` when the game isn't packed, else from its archive.
    static func scripts(inGameFolder folder: URL) -> Data? {
        let data = folder.appending(path: "Data", directoryHint: .isDirectory)
        for name in scriptFiles {
            if let scripts = try? Data(contentsOf: data.appending(path: name)) { return scripts }
        }
        for name in names {
            guard let archive = try? Data(contentsOf: folder.appending(path: name), options: .alwaysMapped) else {
                continue
            }
            return file(in: archive) { name in scriptFiles.contains { name.hasSuffix($0) } }
        }
        return nil
    }

    /// The first file whose name `wanted` takes, decrypted; nil when there is none or the archive is damaged.
    /// Names are read byte for byte as Latin-1: XP and VX wrote them in Shift-JIS, and only ASCII ones are looked
    /// for.
    static func file(in archive: Data, where wanted: (String) -> Bool) -> Data? {
        // Indexed in place, from zero: the archive is mapped, and a game's can be hundreds of megabytes.
        let bytes = archive.startIndex == 0 ? archive : Data(archive)
        guard bytes.count >= 12, bytes.prefix(7).elementsEqual(Array("RGSSAD\0".utf8)) else { return nil }
        switch bytes[7] {
        case 1: return version1(bytes, wanted)
        case 3: return version3(bytes, wanted)
        default: return nil
        }
    }

    /// XP and VX: each entry is its name's length, the name, the data's size and the data, all under one key
    /// that moves on after every word and every name byte. The data's key starts where the entry's left off.
    private static func version1(_ bytes: Data, _ wanted: (String) -> Bool) -> Data? {
        var key: UInt32 = 0xDEAD_CAFE
        var position = 8
        while position + 4 <= bytes.count {
            let length = Int(word(bytes, at: position) ^ key)
            key = next(key)
            position += 4
            guard length > 0, position + length + 4 <= bytes.count else { return nil }
            var name: [UInt8] = []
            for index in 0..<length {
                name.append(bytes[position + index] ^ UInt8(truncatingIfNeeded: key))
                key = next(key)
            }
            position += length
            let size = Int(word(bytes, at: position) ^ key)
            key = next(key)
            position += 4
            guard size >= 0, position + size <= bytes.count else { return nil }
            if wanted(String(bytes: name, encoding: .isoLatin1) ?? "") {
                return decrypt(bytes[position..<(position + size)], key: key)
            }
            position += size
        }
        return nil
    }

    /// VX Ace: a table of entries (offset, size, the data's own key, name) under a key made from the header's
    /// seed, ending with a zero offset.
    private static func version3(_ bytes: Data, _ wanted: (String) -> Bool) -> Data? {
        let key = word(bytes, at: 8) &* 9 &+ 3
        var position = 12
        while position + 16 <= bytes.count {
            let offset = Int(word(bytes, at: position) ^ key)
            let size = Int(word(bytes, at: position + 4) ^ key)
            let dataKey = word(bytes, at: position + 8) ^ key
            let length = Int(word(bytes, at: position + 12) ^ key)
            position += 16
            guard offset != 0 else { return nil }
            guard position + length <= bytes.count, offset + size <= bytes.count else { return nil }
            let name = (0..<length).map { bytes[position + $0] ^ UInt8(truncatingIfNeeded: key >> (8 * ($0 % 4))) }
            position += length
            if wanted(String(bytes: name, encoding: .isoLatin1) ?? "") {
                return decrypt(bytes[offset..<(offset + size)], key: dataKey)
            }
        }
        return nil
    }

    /// XOR with the key word by word, the key moving on after each.
    private static func decrypt(_ data: Data, key start: UInt32) -> Data {
        var key = start
        var result = [UInt8](data)
        var index = 0
        while index < result.count {
            for byte in 0..<min(4, result.count - index) {
                result[index + byte] ^= UInt8(truncatingIfNeeded: key >> (8 * byte))
            }
            key = next(key)
            index += 4
        }
        return Data(result)
    }

    private static func next(_ key: UInt32) -> UInt32 { key &* 7 &+ 3 }

    private static func word(_ bytes: Data, at index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16
            | UInt32(bytes[index + 3]) << 24
    }

    // MARK: - The scripts

    /// The scripts' source. The file is a Ruby array of `[id, name, zlib-compressed source]`; rather than read
    /// Ruby's format, every zlib stream in it is inflated.
    static func source(of scripts: Data) -> String {
        let bytes = [UInt8](scripts)
        var parts: [String] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0x78, bytes[index + 1] == 0x9C, let text = inflate(bytes[(index + 2)...]) {
                parts.append(text)
            }
            index += 1
        }
        return parts.joined(separator: "\n")
    }

    /// Raw deflate up to the end of its stream; nil when the bytes aren't one.
    private static func inflate(_ deflated: ArraySlice<UInt8>) -> String? {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else { return nil }
        defer { compression_stream_destroy(stream) }
        var output = Data()
        let chunk = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        return deflated.withUnsafeBufferPointer { input -> String? in
            guard let base = input.baseAddress else { return nil }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = input.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(buffer, count: chunk - stream.pointee.dst_size)
                switch status {
                case COMPRESSION_STATUS_END: return String(bytes: output, encoding: .utf8)
                case COMPRESSION_STATUS_OK where output.count < 16 * 1024 * 1024: continue
                default: return nil
                }
            }
        }
    }

    /// The largest `resize_screen(width, height)` written with numbers. Nil when there is none, or only calls with
    /// computed sizes, which can't be known before the game runs.
    static func resizedScreen(in source: String) -> GameScaling.Size? {
        let pattern = /resize_screen\s*\(?\s*(\d{3,4})\s*,\s*(\d{3,4})/
        return source.matches(of: pattern).compactMap { match -> GameScaling.Size? in
            guard let width = Int(match.1), let height = Int(match.2) else { return nil }
            return GameScaling.Size(width: width, height: height)
        }.max { $0.width * $0.height < $1.width * $1.height }
    }
}
