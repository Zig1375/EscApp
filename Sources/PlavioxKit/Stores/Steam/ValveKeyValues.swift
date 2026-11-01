import Foundation

/// Valve's KeyValues text, the format of Steam's `appmanifest_*.acf` and `libraryfolders.vdf`:
/// `"key" "value"` pairs and `"key" { … }` blocks, with `//` comments. Keys are matched without case, as Steam
/// itself writes them inconsistently (`installdir`, `InstallDir`).
public indirect enum ValveKeyValues: Sendable, Equatable {
    case value(String)
    case block([(String, ValveKeyValues)])

    public static func == (lhs: ValveKeyValues, rhs: ValveKeyValues) -> Bool {
        switch (lhs, rhs) {
        case let (.value(left), .value(right)): left == right
        case let (.block(left), .block(right)):
            left.count == right.count && zip(left, right).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    public subscript(key: String) -> ValveKeyValues? {
        guard case let .block(entries) = self else { return nil }
        return entries.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
    }

    public var string: String? {
        if case let .value(text) = self { text } else { nil }
    }

    /// The entries of a block, in file order.
    public var entries: [(String, ValveKeyValues)] {
        if case let .block(entries) = self { entries } else { [] }
    }

    /// The whole file as one block. Malformed text gives what was read up to the problem.
    public static func parse(_ text: String) -> ValveKeyValues {
        var tokens = Tokens(Array(text.unicodeScalars))
        return .block(tokens.entries())
    }

    private struct Tokens {
        enum Token { case text(String), open, close }

        let scalars: [Unicode.Scalar]
        var index = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        mutating func entries() -> [(String, ValveKeyValues)] {
            var result: [(String, ValveKeyValues)] = []
            while let token = next() {
                guard case let .text(key) = token else { return result }
                switch next() {
                case let .text(value)?: result.append((key, .value(value)))
                case .open?: result.append((key, .block(entries())))
                case .close?, nil: return result
                }
            }
            return result
        }

        mutating func next() -> Token? {
            while index < scalars.count {
                let scalar = scalars[index]
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    index += 1
                } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                } else if scalar == "{" {
                    index += 1
                    return .open
                } else if scalar == "}" {
                    index += 1
                    return .close
                } else if scalar == "\"" {
                    index += 1
                    var text = String.UnicodeScalarView()
                    while index < scalars.count, scalars[index] != "\"" {
                        // `\\` in paths, `\"` in names.
                        if scalars[index] == "\\", index + 1 < scalars.count {
                            index += 1
                            let escaped = scalars[index]
                            text.append(escaped == "n" ? "\n" : escaped == "t" ? "\t" : escaped)
                        } else {
                            text.append(scalars[index])
                        }
                        index += 1
                    }
                    index += 1
                    return .text(String(text))
                } else {
                    // Unquoted word, as in some hand-edited files.
                    var text = String.UnicodeScalarView()
                    while index < scalars.count, !CharacterSet.whitespacesAndNewlines.contains(scalars[index]),
                          !["{", "}", "\""].contains(scalars[index]) {
                        text.append(scalars[index])
                        index += 1
                    }
                    return .text(String(text))
                }
            }
            return nil
        }
    }
}
