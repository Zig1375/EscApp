import CryptoKit
import Foundation

/// A store game's screenshots from its store page, for the game's page in Magic Kettle (Game.dc.html, "Screenshots").
/// Stores keep only covers and banners on disk, so these come from each store's public pages (`SteamScreenshots`,
/// `EpicScreenshots`). The request names the game and nothing else: no account, no Mac, nothing about the player.
///
/// The list and the small pictures are kept in `Artwork/<store>-<id>`, so the page shows them at once and offline;
/// the list is asked again after a week. Full-size pictures are fetched only when the player opens one.
public enum StoreScreenshots {
    public struct Shot: Codable, Sendable, Equatable, Identifiable {
        public var id: Int
        /// About 600×338.
        public var thumbnail: URL
        /// 1920×1080.
        public var full: URL
    }

    /// Where a game's pictures come from.
    public enum Source: Sendable, Hashable {
        case steam(appID: String)
        /// Epic's pages are found by the catalog namespace, or failing that by the game's name (`EpicScreenshots`).
        case epic(namespace: String, title: String)

        /// The source for a store's game; none for a game the player installed themselves.
        public init?(_ game: GameRecord) {
            guard let id = game.storeID else { return nil }
            switch game.store {
            case .steam?: self = .steam(appID: id)
            case .epic?:
                guard let namespace = EpicStore.namespace(storeID: id) else { return nil }
                self = .epic(namespace: namespace, title: game.name)
            default: return nil
            }
        }

        /// `steam-<app id>` or `epic-<namespace>` under `Artwork`.
        var folderName: String? {
            switch self {
            case .steam(let appID):
                appID.allSatisfy(\.isNumber) && !appID.isEmpty ? "steam-\(appID)" : nil
            case .epic(let namespace, _):
                EpicStore.isCatalogID(namespace) ? "epic-\(namespace)" : nil
            }
        }

        /// Pictures are fetched from the store's own servers only.
        func allows(_ url: URL) -> Bool {
            switch self {
            case .steam: SteamScreenshots.isSteams(url)
            case .epic: EpicScreenshots.isEpics(url)
            }
        }

        func fetch() async -> [Shot]? {
            switch self {
            case .steam(let appID): await SteamScreenshots.fetch(appID: appID)
            case .epic(let namespace, let title): await EpicScreenshots.fetch(namespace: namespace, title: title)
            }
        }
    }

    static let maxAge: TimeInterval = 7 * 24 * 3600
    static let prefixes = ["steam-", "epic-"]

    static func folder(_ source: Source, paths: AppPaths) -> URL? {
        source.folderName.map { paths.artwork.appending(path: $0, directoryHint: .isDirectory) }
    }

    /// Removes the kept pictures of store games no longer in the library: deleted in Magic Kettle, uninstalled in their
    /// store, or gone with the store itself. Run with each store sync, which is where all of those are noticed.
    public static func prune(keeping sources: Set<Source>, paths: AppPaths) {
        let kept = Set(sources.compactMap(\.folderName))
        let fileManager = FileManager.default
        for name in (try? fileManager.contentsOfDirectory(atPath: paths.artwork.path)) ?? []
        where prefixes.contains(where: name.hasPrefix) && !kept.contains(name) {
            try? fileManager.removeItem(at: paths.artwork.appending(path: name, directoryHint: .isDirectory))
        }
    }

    /// The list kept from last time, however old.
    public static func cached(_ source: Source, paths: AppPaths) -> [Shot]? {
        guard let file = folder(source, paths: paths)?.appending(path: "screenshots.json") else { return nil }
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Shot].self, from: $0) }
    }

    /// The game's screenshots: kept ones while fresh, otherwise asked from the store (kept ones when that fails).
    public static func load(_ source: Source, paths: AppPaths, now: Date = Date()) async -> [Shot] {
        guard let file = folder(source, paths: paths)?.appending(path: "screenshots.json") else { return [] }
        let kept = cached(source, paths: paths)
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let kept, let modified, now.timeIntervalSince(modified) < maxAge { return kept }
        guard let shots = await source.fetch() else { return kept ?? [] }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(shots).write(to: file, options: .atomic)
        return shots
    }

    /// The small picture on disk, fetched the first time.
    public static func thumbnail(_ shot: Shot, of source: Source, paths: AppPaths) async -> URL? {
        await picture(shot.thumbnail, of: source, paths: paths)
    }

    /// The full picture on disk, fetched the first time it is opened.
    public static func full(_ shot: Shot, of source: Source, paths: AppPaths) async -> URL? {
        await picture(shot.full, of: source, paths: paths)
    }

    private static func picture(_ url: URL, of source: Source, paths: AppPaths) async -> URL? {
        guard source.allows(url), let folder = folder(source, paths: paths) else { return nil }
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return await download(url, to: folder.appending(path: name + ".jpg"))
    }

    /// `url` saved as `file`, unless it is there already.
    static func download(_ url: URL, to file: URL) async -> URL? {
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return file
    }
}
