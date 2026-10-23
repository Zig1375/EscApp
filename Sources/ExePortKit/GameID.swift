import Foundation

/// Stable identity of a game. It is written to the `.exeport` file in the game folder and names the game's bottle,
/// logs and screenshots, so it must stay valid as a single path component.
public struct GameID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    /// Accepts only what `GameID.make()` produces (an uppercase UUID). A hand-edited `.exeport` with anything else,
    /// such as `../..`, would otherwise point a bottle outside `Bottles/`.
    public init?(rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue), uuid.uuidString == rawValue else { return nil }
        self.rawValue = rawValue
    }

    private init(uuid: UUID) {
        rawValue = uuid.uuidString
    }

    public static func make() -> GameID {
        GameID(uuid: UUID())
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let id = GameID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a game id: \(raw)")
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
