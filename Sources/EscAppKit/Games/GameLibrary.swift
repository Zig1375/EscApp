import Foundation
import Synchronization

/// One game EscApp knows about.
public struct GameRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: GameID
    public var name: String
    /// The executable last opened for this game.
    public var executable: String
    /// The game's folder: where its `.escapp` file is, or the executable's folder when there is none.
    public var folder: String
    /// False when EscApp couldn't write `.escapp` (disc image, read-only folder); the game is then found again by
    /// path or fingerprint.
    public var hasMarker: Bool
    /// SHA-256 of the executable plus the folder's file list. Only computed for games without a marker.
    public var fingerprint: String?
    public var windowsVersion: WindowsVersion
    public var addedAt: Date
    public var lastPlayed: Date?
    /// The backend that ran this game last time; tried first from now on.
    public var backend: GraphicsBackend?
    /// Total seconds played.
    public var playTime: TimeInterval?
    public var launches: Int?

    public init(id: GameID, name: String, executable: String, folder: String, hasMarker: Bool,
                fingerprint: String? = nil, windowsVersion: WindowsVersion = .default, addedAt: Date,
                lastPlayed: Date? = nil, backend: GraphicsBackend? = nil, playTime: TimeInterval? = nil) {
        self.id = id
        self.name = name
        self.executable = executable
        self.folder = folder
        self.hasMarker = hasMarker
        self.fingerprint = fingerprint
        self.windowsVersion = windowsVersion
        self.addedAt = addedAt
        self.lastPlayed = lastPlayed
        self.backend = backend
        self.playTime = playTime
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

    /// Notes a finished session: when, for how long, and the backend that worked, if one did. A failed run keeps
    /// the backend remembered before (a crash at start shouldn't become the remembered choice).
    public mutating func recordPlay(of id: GameID, duration: TimeInterval, working: GraphicsBackend?,
                                    endedAt: Date = Date()) {
        guard var game = self[id] else { return }
        game.lastPlayed = endedAt
        game.playTime = (game.playTime ?? 0) + duration
        game.launches = (game.launches ?? 0) + 1
        if let working { game.backend = working }
        self[id] = game
    }

    /// Reads, changes and writes `Games.json` as one step. Launches record their results from background
    /// tasks, so two games ending together (or a launch and a settings change) each loaded the file, and
    /// whichever saved last wiped out the other's change. The lock file covers the CLI running alongside the app.
    public static func modify<T>(_ file: URL, _ change: (inout GameLibrary) throws -> T) throws -> T {
        try lock.withLock { _ in
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let descriptor = open(file.path(percentEncoded: false) + ".lock", O_CREAT | O_RDWR, 0o644)
            if descriptor >= 0 { flock(descriptor, LOCK_EX) }
            defer {
                if descriptor >= 0 {
                    flock(descriptor, LOCK_UN)
                    close(descriptor)
                }
            }
            var library = try load(from: file)
            let result = try change(&library)
            try library.save(to: file)
            return result
        }
    }

    private static let lock = Mutex(())

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
