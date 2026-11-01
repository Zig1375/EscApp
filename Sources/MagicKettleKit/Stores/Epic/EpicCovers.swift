import Foundation

/// An Epic game's portrait cover, for its card in the library. Unlike Steam, the launcher keeps no pictures on
/// disk, but its catalog cache (`catcache.bin`: base64 of a JSON list of every item it has seen) names each
/// game's covers on Epic's image servers. The tall one (`DieselGameBoxTall`, 3:4, as the store shows it) is
/// fetched once into `Artwork/epic-<namespace>/cover.jpg` and kept with the game's screenshots.
public enum EpicCovers {
    static func catalog(bottle: URL) -> URL {
        bottle.appending(path: "drive_c/ProgramData/Epic/EpicGamesLauncher/Data/Catalog/catcache.bin")
    }

    static func file(namespace: String, paths: AppPaths) -> URL? {
        StoreScreenshots.folder(.epic(namespace: namespace, title: ""), paths: paths)?.appending(path: "cover.jpg")
    }

    /// The kept cover, if it was fetched before.
    public static func cached(storeID: String, paths: AppPaths) -> URL? {
        guard let namespace = EpicStore.namespace(storeID: storeID),
              let file = file(namespace: namespace, paths: paths),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }

    /// The game's cover: the kept one, or fetched from where the launcher's catalog says it is.
    public static func cover(storeID: String, bottle: URL, paths: AppPaths) async -> URL? {
        guard let namespace = EpicStore.namespace(storeID: storeID), let item = EpicStore.catalogItem(storeID: storeID),
              let file = file(namespace: namespace, paths: paths) else { return nil }
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let catalog = try? Data(contentsOf: catalog(bottle: bottle)),
              let url = coverURL(catalog: catalog, item: item) else { return nil }
        return await StoreScreenshots.download(url, to: file)
    }

    /// `[{"id":"36b1…","namespace":"6144…","keyImages":[{"type":"DieselGameBoxTall","url":"https://cdn1…"}]}]`,
    /// base64-encoded. Only a picture on Epic's own servers.
    static func coverURL(catalog: Data, item: String) -> URL? {
        struct Item: Decodable {
            var id: String
            var keyImages: [KeyImage]?
        }
        struct KeyImage: Decodable {
            var type: String
            var url: String
        }
        guard let json = Data(base64Encoded: catalog, options: .ignoreUnknownCharacters),
              let items = try? JSONDecoder().decode([Item].self, from: json),
              let images = items.first(where: { $0.id == item })?.keyImages else { return nil }
        for type in ["DieselGameBoxTall", "OfferImageTall"] {
            if let image = images.first(where: { $0.type == type }), let url = URL(string: image.url),
               EpicScreenshots.isEpics(url) { return url }
        }
        return nil
    }
}
