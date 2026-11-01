import Foundation

/// Reads and writes string values in Wine's registry files (`user.reg`, `system.reg`) as text.
///
/// Editing the file directly takes milliseconds, where `wine reg add` starts Wine (a second or more per value).
/// It is only safe while no wineserver runs for the bottle: wineserver keeps the registry in memory and writes
/// the whole file back when it exits, which would undo the edit.
public enum WineRegistry {
    /// - Parameter key: relative to the file's root, as Windows writes it: `Software\Wine`.
    public static func string(in text: String, key: String, name: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let section = sectionRange(in: lines, key: key) else { return nil }
        for line in lines[section] {
            if let (lineName, value) = parseValue(line), lineName.caseInsensitiveCompare(name) == .orderedSame {
                return value
            }
        }
        return nil
    }

    /// `"Name"=dword:00000060` → 96. Other value types, and a value that isn't there, return nil.
    public static func dword(in text: String, key: String, name: String) -> UInt32? {
        let lines = text.components(separatedBy: "\n")
        guard let section = sectionRange(in: lines, key: key) else { return nil }
        for line in lines[section] {
            if let (lineName, value) = parseDWord(line), lineName.caseInsensitiveCompare(name) == .orderedSame {
                return value
            }
        }
        return nil
    }

    /// Returns `text` with the value set, adding the key if it doesn't exist yet.
    public static func setString(in text: String, key: String, name: String, value: String,
                                 now: Date = Date()) -> String {
        setEntry(in: text, key: key, name: name, entry: "\(quote(name))=\(quote(value))", now: now)
    }

    /// `"Name"=dword:0000000a`.
    public static func setDWord(in text: String, key: String, name: String, value: UInt32,
                                now: Date = Date()) -> String {
        let hex = String(value, radix: 16)
        let entry = "\(quote(name))=dword:\(String(repeating: "0", count: 8 - hex.count))\(hex)"
        return setEntry(in: text, key: key, name: name, entry: entry, now: now)
    }

    /// Whether `text` already has exactly this line in the key, so a file isn't rewritten for nothing.
    static func contains(_ text: String, key: String, entry: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        return sectionRange(in: lines, key: key).map { lines[$0].contains(entry) } ?? false
    }

    private static func setEntry(in text: String, key: String, name: String, entry: String, now: Date) -> String {
        var lines = text.components(separatedBy: "\n")
        let stamp = Int(now.timeIntervalSince1970)

        guard let section = sectionRange(in: lines, key: key) else {
            // A new key goes at the end, separated by a blank line like Wine writes it.
            while lines.last?.isEmpty == true { lines.removeLast() }
            lines += ["", "[\(escapeKey(key))] \(stamp)", "#time=\(String(stamp, radix: 16))", entry, ""]
            return lines.joined(separator: "\n")
        }
        // Any value of that name, whatever its type, is replaced.
        if let index = lines[section].firstIndex(where: {
            readQuoted(Substring($0)).map { $0.0.caseInsensitiveCompare(name) == .orderedSame && $0.1.hasPrefix("=") }
                ?? false
        }) {
            lines[index] = entry
        } else {
            // After the header and its `#time`/`#class` lines, before the values.
            var insert = section.lowerBound
            while insert < section.upperBound, lines[insert].hasPrefix("#") { insert += 1 }
            lines.insert(entry, at: insert)
        }
        return lines.joined(separator: "\n")
    }

    /// The lines of a key's body: after its `[...]` header, up to the next header.
    private static func sectionRange(in lines: [String], key: String) -> Range<Int>? {
        let wanted = escapeKey(key).lowercased()
        guard let header = lines.firstIndex(where: { line in
            guard line.hasPrefix("["), let end = line.lastIndex(of: "]") else { return false }
            return line[line.index(after: line.startIndex)..<end].lowercased() == wanted
        }) else { return nil }
        let start = header + 1
        let end = lines[start...].firstIndex { $0.hasPrefix("[") } ?? lines.count
        return start..<end
    }

    /// `"Name"="value"` → (Name, value). Other value types (`dword:`, `hex:`) aren't strings and return nil.
    private static func parseValue(_ line: String) -> (String, String)? {
        guard line.hasPrefix("\""), let (name, rest) = readQuoted(Substring(line)), rest.hasPrefix("=\""),
              let (value, tail) = readQuoted(rest.dropFirst()), tail.isEmpty
        else { return nil }
        return (name, value)
    }

    /// `"Name"=dword:00000060` → (Name, 96). Strings and other value types return nil.
    private static func parseDWord(_ line: String) -> (String, UInt32)? {
        guard line.hasPrefix("\""), let (name, rest) = readQuoted(Substring(line)),
              rest.hasPrefix("=dword:")
        else { return nil }
        return UInt32(rest.dropFirst("=dword:".count), radix: 16).map { (name, $0) }
    }

    /// Reads a quoted, backslash-escaped string at the start of `text`; returns it and what follows. `\x30b4` is
    /// a UTF-16 unit, the way Wine writes everything outside ASCII.
    private static func readQuoted(_ text: Substring) -> (String, Substring)? {
        guard text.first == "\"" else { return nil }
        var result = ""
        var units: [UInt16] = []
        func flush() {
            result += String(decoding: units, as: UTF16.self)
            units = []
        }
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                index = text.index(after: index)
                guard index < text.endIndex else { return nil }
                if text[index] == "x", let (unit, end) = hexEscape(text, after: index) {
                    units.append(unit)
                    index = end
                    continue
                }
                flush()
                result.append(text[index])
            } else if character == "\"" {
                flush()
                return (result, text[text.index(after: index)...])
            } else {
                flush()
                result.append(character)
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The up to four hex digits after the `x` at `index`, and where they end.
    private static func hexEscape(_ text: Substring, after index: Substring.Index) -> (UInt16, Substring.Index)? {
        var end = text.index(after: index)
        var digits = ""
        while end < text.endIndex, digits.count < 4, text[end].isHexDigit {
            digits.append(text[end])
            end = text.index(after: end)
        }
        return UInt16(digits, radix: 16).map { ($0, end) }
    }

    /// Escapes as Wine does, so Wine reads non-ASCII names back (Japanese font names): four hex digits per UTF-16
    /// unit, always four, so a hex digit that follows can't be taken into the escape.
    private static func quote(_ string: String) -> String {
        var result = "\""
        for unit in string.utf16 {
            switch unit {
            case 0x5C: result += "\\\\"
            case 0x22: result += "\\\""
            case 0x20..<0x7F: result.append(Character(Unicode.Scalar(UInt8(unit))))
            default: result += "\\x" + String(repeating: "0", count: 4 - String(unit, radix: 16).count)
                + String(unit, radix: 16)
            }
        }
        return result + "\""
    }

    /// Key paths store each backslash doubled: `Software\Wine` is written `[Software\\Wine]`.
    private static func escapeKey(_ key: String) -> String {
        key.replacingOccurrences(of: "\\", with: "\\\\")
    }
}

extension WindowsVersion {
    static let registryKey = #"Software\Wine"#
    static let registryValue = "Version"

    /// The version set in a bottle's `user.reg`, or nil when Wine's default applies.
    public static func read(fromUserReg text: String) -> WindowsVersion? {
        WineRegistry.string(in: text, key: registryKey, name: registryValue).flatMap(WindowsVersion.init(wineValue:))
    }

    public func write(toUserReg text: String) -> String {
        WineRegistry.setString(in: text, key: Self.registryKey, name: Self.registryValue, value: wineValue)
    }
}
