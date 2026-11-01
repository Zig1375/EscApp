import Foundation
import ImageIO

/// A cover the player picked for a game. Steam keeps covers of its games (`SteamCovers`), but a game installed
/// from a disc or an installer has none, only its icon. The picture is copied to `Artwork/cover-<game id>.<ext>`,
/// so it stays when the original is moved or deleted, and goes when the game leaves the library.
public enum CustomCovers {
    static let prefix = "cover-"

    public enum CoverError: Error, Equatable {
        case notAnImage
    }

    /// The game's cover, if the player chose one.
    public static func cover(for game: GameID, paths: AppPaths) -> URL? {
        files(paths: paths).first { id(of: $0) == game.rawValue }
    }

    /// Copies `picture` in as the game's cover, replacing an earlier one. Anything ImageIO can't read is refused,
    /// so a renamed document doesn't end up as a blank card.
    @discardableResult
    public static func set(_ picture: URL, for game: GameID, paths: AppPaths) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(picture as CFURL, nil), CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw CoverError.notAnImage }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.artwork, withIntermediateDirectories: true)
        let ext = picture.pathExtension.isEmpty ? "img" : picture.pathExtension.lowercased()
        let target = paths.artwork.appending(path: "\(prefix)\(game.rawValue).\(ext)")
        let staging = paths.artwork.appending(path: ".\(prefix)\(game.rawValue).\(UUID().uuidString)")
        try fileManager.copyItem(at: picture, to: staging)
        remove(for: game, paths: paths)
        try fileManager.moveItem(at: staging, to: target)
        return target
    }

    public static func remove(for game: GameID, paths: AppPaths) {
        for file in files(paths: paths) where id(of: file) == game.rawValue {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Removes the covers of games no longer in the library.
    public static func prune(keeping games: Set<GameID>, paths: AppPaths) {
        let kept = Set(games.map(\.rawValue))
        for file in files(paths: paths) where !kept.contains(id(of: file)) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func files(paths: AppPaths) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: paths.artwork, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    /// `cover-<id>.png` → `<id>`.
    private static func id(of file: URL) -> String {
        String(file.deletingPathExtension().lastPathComponent.dropFirst(prefix.count))
    }
}
