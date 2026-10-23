import Foundation

/// "Remove from ExePort": forgets the game without touching the game itself or its saves.
public enum GameRemover {
    /// Deletes the game's entry, its bottle, its logs and its `.exeport` file. The game folder and the shared profile
    /// (saves) stay; opening the exe again adds the game back as new.
    public static func removeFromApp(_ id: GameID, paths: AppPaths) throws {
        var library = try GameLibrary.load(from: paths.library)
        guard let game = library[id] else { return }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: paths.bottle(forGame: id))
        try? fileManager.removeItem(at: paths.logs(forGame: id))
        if game.hasMarker {
            let marker = URL(filePath: game.folder, directoryHint: .isDirectory)
                .appending(path: GameIdentifier.markerName)
            // Only a .exeport that still names this game: the folder may have been reused by another one.
            if let data = try? Data(contentsOf: marker),
               let found = try? JSONDecoder().decode(GameIdentifier.Marker.self, from: data), found.id == id {
                try? fileManager.removeItem(at: marker)
            }
        }
        library[id] = nil
        try library.save(to: paths.library)
    }
}
