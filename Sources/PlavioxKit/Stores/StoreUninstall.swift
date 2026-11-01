import Foundation

/// "Delete" on a store game, once confirmed, without opening the store: the game's folder and the store's own
/// record of it go to the Trash, so the store shows it as not installed. Only for stores that record their games in
/// files (`StoreModule.removesGamesWithoutClient`: Steam, Epic); a store that keeps them in the registry removes
/// its games itself.
public enum StoreUninstall {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notFound(String)

        public var description: String {
            switch self {
            case let .notFound(name): "\(name) isn't installed where its store says it is."
            }
        }
    }

    public static func canRemove(_ store: Store) -> Bool { store.module.removesGamesWithoutClient }

    /// Moves the game's folder to the Trash and drops the store's record of it. The game must not be running.
    /// - Parameter trash: moves the folder to the Trash; tests delete it instead.
    public static func remove(_ game: GameRecord, paths: AppPaths, trash: (URL) throws -> Void = moveToTrash) throws {
        guard let store = game.store, let id = game.storeID, canRemove(store) else { return }
        let bottle = paths.bottle(forGame: store.bottleID)
        let folder = URL(filePath: game.folder, directoryHint: .isDirectory)
        let records = store.module.records(ofGame: id, folder: folder, bottle: bottle)
        guard !records.isEmpty || FileManager.default.fileExists(atPath: folder.path) else {
            throw Failure.notFound(game.name)
        }
        if FileManager.default.fileExists(atPath: folder.path) {
            try trash(folder)
        }
        // The records go to the Trash too: "Put Back" there restores the game whole, as the store knew it.
        for record in records { try? trash(record) }
        try? store.module.forgetGame(id, bottle: bottle)
        _ = try StoreLibrary.sync(paths: paths)
    }

    public static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
