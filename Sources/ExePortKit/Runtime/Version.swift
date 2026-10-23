/// A dotted version such as `0.1.0`, `11.18` or `15.0`. Missing parts count as zero, so `15` == `15.0.0`.
public struct Version: Comparable, Hashable, Sendable, CustomStringConvertible, Codable {
    public let parts: [Int]

    public init?(_ string: String) {
        let pieces = string.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = pieces.compactMap { Int($0) }
        guard !pieces.isEmpty, numbers.count == pieces.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        parts = numbers
    }

    /// Stands in when a version can't be read (an odd macOS string), so comparisons stay conservative.
    public static let zero = Version(validParts: [0])

    private init(validParts: [Int]) {
        parts = validParts
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = lhs.part(index), right = rhs.part(index)
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: Version, rhs: Version) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    public func hash(into hasher: inout Hasher) {
        // Equal versions must hash equally, so trailing zeros don't count.
        var trimmed = parts
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }

    private func part(_ index: Int) -> Int { index < parts.count ? parts[index] : 0 }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let version = Version(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a version: \(string)")
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
