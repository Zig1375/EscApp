import Foundation

/// One game Rum knows about.
public struct GameRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: GameID
    public var name: String
    /// The executable last opened for this game.
    public var executable: String
    /// The game's folder: where its `.rum` file is, or the executable's folder when there is none.
    public var folder: String
    /// False when Rum couldn't write `.rum` (disc image, read-only folder); the game is then found again by
    /// path or fingerprint.
    public var hasMarker: Bool
    /// SHA-256 of the executable plus the folder's file list. Only computed for games without a marker.
    public var fingerprint: String?
    public var windowsVersion: WindowsVersion
    public var addedAt: Date
    public var lastPlayed: Date?

    public init(id: GameID, name: String, executable: String, folder: String, hasMarker: Bool,
                fingerprint: String? = nil, windowsVersion: WindowsVersion = .default, addedAt: Date,
                lastPlayed: Date? = nil) {
        self.id = id
        self.name = name
        self.executable = executable
        self.folder = folder
        self.hasMarker = hasMarker
        self.fingerprint = fingerprint
        self.windowsVersion = windowsVersion
        self.addedAt = addedAt
        self.lastPlayed = lastPlayed
    }
}

/// `Games.json`: every known game.
public struct GameLibrary: Codable, Sendable, Equatable {
    public var format = 1
    public var games: [GameRecord] = []

    public init(games: [GameRecord] = []) {
        self.games = games
    }

    public subscript(id: GameID) -> GameRecord? {
        get { games.first { $0.id == id } }
        set {
            let index = games.firstIndex { $0.id == id }
            switch (index, newValue) {
            case let (index?, record?): games[index] = record
            case let (index?, nil): games.remove(at: index)
            case let (nil, record?): games.append(record)
            case (nil, nil): break
            }
        }
    }

    public static func load(from file: URL) throws -> GameLibrary {
        guard FileManager.default.fileExists(atPath: file.path) else { return GameLibrary() }
        return try JSONDecoder.iso.decode(GameLibrary.self, from: Data(contentsOf: file))
    }

    public func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder.iso
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
    }
}
