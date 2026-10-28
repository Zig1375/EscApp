import Foundation

/// A store game's portrait cover: Steam's from its own cache (`SteamCovers`), Epic's from where the launcher's
/// catalog says it is (`EpicCovers`). None for a game the player installed themselves.
public enum StoreCovers {
    public static func cover(for game: GameRecord, paths: AppPaths) async -> URL? {
        guard let id = game.storeID else { return nil }
        let stores = StoreClient(paths: paths)
        switch game.store {
        case .steam?:
            let steam = SteamCovers.steamFolder(bottle: stores.bottle(for: .steam))
            return SteamCovers.cover(appID: id, steamFolder: steam)
        case .epic?: return await EpicCovers.cover(storeID: id, bottle: stores.bottle(for: .epic), paths: paths)
        default: return nil
        }
    }
}
