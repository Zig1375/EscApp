import Foundation

/// Reads the target of a Windows shortcut (`.lnk`). An installer's Start menu shortcut is the most reliable sign of
/// which program starts the game, so the install screen recommends its target.
///
/// Only the parts that carry the target are read (MS-SHLLINK): the LinkInfo's local path, or else the relative
/// path among the strings. Wine's shell writes both for a shortcut made with `IShellLink`.
public enum ShellLink {
    public static func target(of file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return target(in: data)
    }

    private enum Flag {
        static let hasIDList: UInt32 = 0x01
        static let hasLinkInfo: UInt32 = 0x02
        static let hasName: UInt32 = 0x04
        static let hasRelativePath: UInt32 = 0x08
        static let unicode: UInt32 = 0x80
    }

    static func target(in data: Data) -> String? {
        guard data.u32le(0) == 0x4C, let flags = data.u32le(0x14) else { return nil }
        var cursor = 0x4C
        if flags & Flag.hasIDList != 0 {
            guard let size = data.u16le(cursor) else { return nil }
            cursor += 2 + Int(size)
        }
        var path: String?
        if flags & Flag.hasLinkInfo != 0 {
            guard let size = data.u32le(cursor) else { return nil }
            path = localPath(in: data, linkInfo: cursor)
            cursor += Int(size)
        }
        if path == nil, flags & Flag.hasRelativePath != 0 {
            let unicode = flags & Flag.unicode != 0
            if flags & Flag.hasName != 0 { cursor = skipString(in: data, at: cursor, unicode: unicode) ?? data.count }
            path = string(in: data, at: cursor, unicode: unicode)
        }
        return path.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// LinkInfo: size, header size, flags, volume ID offset, local base path offset, …, and from header size
    /// 0x24 on, a Unicode local base path offset too.
    private static func localPath(in data: Data, linkInfo start: Int) -> String? {
        guard let headerSize = data.u32le(start + 4), let flags = data.u32le(start + 8), flags & 1 != 0 else {
            return nil
        }
        if headerSize >= 0x24, let offset = data.u32le(start + 0x1C), offset != 0,
           let path = cString(in: data, at: start + Int(offset), unicode: true) {
            return path
        }
        guard let offset = data.u32le(start + 0x10) else { return nil }
        return cString(in: data, at: start + Int(offset), unicode: false)
    }

    /// StringData: a character count, then that many characters.
    private static func string(in data: Data, at offset: Int, unicode: Bool) -> String? {
        guard let count = data.u16le(offset) else { return nil }
        let length = Int(count) * (unicode ? 2 : 1)
        guard offset + 2 + length <= data.count else { return nil }
        let bytes = data.subdata(in: data.startIndex + offset + 2..<data.startIndex + offset + 2 + length)
        return String(data: bytes, encoding: unicode ? .utf16LittleEndian : .windowsCP1252)
    }

    private static func skipString(in data: Data, at offset: Int, unicode: Bool) -> Int? {
        data.u16le(offset).map { offset + 2 + Int($0) * (unicode ? 2 : 1) }
    }

    private static func cString(in data: Data, at offset: Int, unicode: Bool) -> String? {
        var end = offset
        let step = unicode ? 2 : 1
        while end + step <= data.count, unicode ? data.u16le(end) != 0 : data[data.startIndex + end] != 0 {
            end += step
        }
        guard end + step <= data.count else { return nil }
        let bytes = data.subdata(in: data.startIndex + offset..<data.startIndex + end)
        return String(data: bytes, encoding: unicode ? .utf16LittleEndian : .windowsCP1252)
    }
}

/// Windows paths inside a bottle, turned into Mac paths through its drive letters (`dosdevices`).
public enum WindowsPath {
    /// `G:\Probe Game\game.exe` → the file on the Mac, if the drive exists in the bottle. Letters and names are
    /// matched without case, as Windows does.
    public static func macURL(for path: String, bottle: URL) -> URL? {
        let parts = path.replacingOccurrences(of: "/", with: "\\").split(separator: "\\").map(String.init)
        guard let drive = parts.first, drive.count == 2, drive.hasSuffix(":") else { return nil }
        let link = bottle.appending(path: "dosdevices/\(drive.lowercased())")
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return nil
        }
        var url = destination.hasPrefix("/") ? URL(filePath: destination, directoryHint: .isDirectory)
            : bottle.appending(path: "dosdevices").appending(path: destination, directoryHint: .isDirectory)
        for part in parts.dropFirst() {
            url = matching(part, in: url) ?? url.appending(path: part)
        }
        return url.standardizedFileURL
    }

    private static func matching(_ name: String, in folder: URL) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if entries.contains(name) { return folder.appending(path: name) }
        return entries.first { $0.caseInsensitiveCompare(name) == .orderedSame }.map { folder.appending(path: $0) }
    }

    /// The Windows path of a Mac folder under the drive that `drive` links to: `~/Games/Fallout 2` → `G:\Fallout 2`.
    /// Compares the paths as written: `standardizedFileURL` drops `/private` only from paths that exist, which
    /// made `~/Games` and a game folder not created yet look unrelated under `/private/tmp`.
    public static func windowsPath(of url: URL, under root: URL, drive: Character) -> String? {
        let base = root.standardized.path(percentEncoded: false)
        let full = url.standardized.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard full == base || full.hasPrefix(prefix) else { return nil }
        let rest = full == base ? "" : String(full.dropFirst(prefix.count))
        return "\(drive.uppercased()):\\" + rest.split(separator: "/").joined(separator: "\\")
    }
}
