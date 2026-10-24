import Foundation

/// One of Wine's registry files (`system.reg`, `user.reg`, `userdef.reg`) as keys and values, for moving what a
/// game changed in its registry into a bottle made by a newer Wine.
///
/// It keeps every line it doesn't need to understand as it was, so a file read and written back is unchanged.
/// Like `WineRegistry`, only use it on files whose bottle has no wineserver running.
struct RegistryFile: Equatable {
    struct Key: Equatable {
        /// `[Software\\Wine] 1792799262`, as Wine wrote it.
        var header: String
        /// The key path between the brackets, still escaped (`Software\\Wine`).
        var path: String
        var lines: [Line]

        var values: [(name: String, text: String)] {
            lines.compactMap { if case let .value(name, text) = $0 { (name, text) } else { nil } }
        }

        func value(_ name: String) -> String? {
            let wanted = name.lowercased()
            return values.first { $0.name.lowercased() == wanted }?.text
        }
    }

    enum Line: Equatable {
        /// `"Name"=…` or `@=…`; `name` is the part before `=`, quotes included. A value continued over several
        /// lines (long `hex:` data) is one `text` with its line breaks.
        case value(name: String, text: String)
        /// `#time=…`, `#class=…`, blank lines.
        case other(String)
    }

    /// The lines before the first key (`WINE REGISTRY Version 2`, `#arch=win64`).
    var preamble: [String]
    var keys: [Key]

    init(_ text: String) {
        var preamble: [String] = []
        var keys: [Key] = []
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            var line = lines[index]
            index += 1
            if line.hasPrefix("["), let end = line.lastIndex(of: "]") {
                let path = String(line[line.index(after: line.startIndex)..<end])
                keys.append(Key(header: line, path: path, lines: []))
                continue
            }
            guard !keys.isEmpty else {
                preamble.append(line)
                continue
            }
            guard let name = Self.valueName(line) else {
                keys[keys.count - 1].lines.append(.other(line))
                continue
            }
            // A trailing backslash continues the value on the next line.
            while line.hasSuffix("\\"), index < lines.count {
                line += "\n" + lines[index]
                index += 1
            }
            keys[keys.count - 1].lines.append(.value(name: name, text: line))
        }
        self.preamble = preamble
        self.keys = keys
    }

    var text: String {
        var lines = preamble
        for key in keys {
            lines.append(key.header)
            for line in key.lines {
                switch line {
                case let .value(_, text): lines.append(text)
                case let .other(text): lines.append(text)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    func key(_ path: String) -> Key? {
        let wanted = path.lowercased()
        return keys.first { $0.path.lowercased() == wanted }
    }

    /// What `changed` has that `base` doesn't: whole keys `base` lacks, and the values of other keys that are new
    /// or differ. Values or keys the game removed aren't returned: removing settings is rare, and leaving one of
    /// Wine's defaults in place is harmless.
    /// - Parameters:
    ///   - skipping: keys whose values Wine itself rewrites on every start (see `BottleMigration`).
    ///   - onlyMissing: return only what `base` lacks entirely, not values that differ.
    static func changes(from base: RegistryFile, to changed: RegistryFile, skipping: [String] = [],
                        onlyMissing: Bool = false) -> [Key] {
        let skipped = skipping.map { $0.replacingOccurrences(of: "\\", with: "\\\\").lowercased() }
        let baseKeys = Dictionary(base.keys.map { ($0.path.lowercased(), $0) }) { first, _ in first }
        var result: [Key] = []
        for key in changed.keys {
            let path = key.path.lowercased()
            if skipped.contains(where: { path == $0 || path.hasPrefix($0 + "\\\\") }) { continue }
            guard let old = baseKeys[path] else {
                result.append(key)
                continue
            }
            let values = key.lines.filter { line in
                guard case let .value(name, text) = line else { return false }
                guard let before = old.value(name) else { return true }
                return !onlyMissing && before != text
            }
            if !values.isEmpty { result.append(Key(header: key.header, path: key.path, lines: values)) }
        }
        return result
    }

    /// Writes each key's values in, replacing values of the same name, and adds the keys this file lacks.
    mutating func apply(_ changes: [Key]) {
        var index: [String: Int] = [:]
        for (position, key) in keys.enumerated() where index[key.path.lowercased()] == nil {
            index[key.path.lowercased()] = position
        }
        for change in changes {
            guard let position = index[change.path.lowercased()] else {
                // A new key goes at the end, followed by a blank line like Wine writes it.
                var key = change
                if key.lines.last != .other("") { key.lines.append(.other("")) }
                if let last = keys.indices.last, keys[last].lines.last != .other("") {
                    keys[last].lines.append(.other(""))
                }
                index[change.path.lowercased()] = keys.count
                keys.append(key)
                continue
            }
            for case let .value(name, text) in change.lines {
                keys[position].set(name: name, text: text)
            }
        }
    }

    /// `"Name"=…` → `"Name"`, `@=…` → `@`; nil for lines that aren't values.
    private static func valueName(_ line: String) -> String? {
        if line.hasPrefix("@=") { return "@" }
        guard line.hasPrefix("\"") else { return nil }
        var escaped = false
        for index in line.indices.dropFirst() {
            let character = line[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                let after = line.index(after: index)
                guard after < line.endIndex, line[after] == "=" else { return nil }
                return String(line[...index])
            }
        }
        return nil
    }
}

private extension RegistryFile.Key {
    mutating func set(name: String, text: String) {
        let wanted = name.lowercased()
        if let position = lines.firstIndex(where: {
            if case let .value(existing, _) = $0 { existing.lowercased() == wanted } else { false }
        }) {
            lines[position] = .value(name: name, text: text)
            return
        }
        // After the last value, or after the `#time`/`#class` lines; before the blank line that ends the key.
        var insert = lines.count
        while insert > 0, lines[insert - 1] == .other("") { insert -= 1 }
        lines.insert(.value(name: name, text: text), at: insert)
    }
}
