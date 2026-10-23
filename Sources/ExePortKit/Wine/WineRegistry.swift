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

    /// Returns `text` with the value set, adding the key if it doesn't exist yet.
    public static func setString(in text: String, key: String, name: String, value: String,
                                 now: Date = Date()) -> String {
        var lines = text.components(separatedBy: "\n")
        let entry = "\(quote(name))=\(quote(value))"
        let stamp = Int(now.timeIntervalSince1970)

        guard let section = sectionRange(in: lines, key: key) else {
            // A new key goes at the end, separated by a blank line like Wine writes it.
            while lines.last?.isEmpty == true { lines.removeLast() }
            lines += ["", "[\(escapeKey(key))] \(stamp)", "#time=\(String(stamp, radix: 16))", entry, ""]
            return lines.joined(separator: "\n")
        }
        if let index = lines[section].firstIndex(where: {
            parseValue($0).map { $0.0.caseInsensitiveCompare(name) == .orderedSame } ?? false
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

    /// Reads a quoted, backslash-escaped string at the start of `text`; returns it and what follows.
    private static func readQuoted(_ text: Substring) -> (String, Substring)? {
        guard text.first == "\"" else { return nil }
        var result = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                index = text.index(after: index)
                guard index < text.endIndex else { return nil }
                result.append(text[index])
            } else if character == "\"" {
                return (result, text[text.index(after: index)...])
            } else {
                result.append(character)
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func quote(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
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
