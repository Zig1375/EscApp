import CryptoKit
import Foundation

/// A Steam game's screenshots from its store page, for the game's page in EscApp (Game.dc.html, "Screenshots").
/// Steam keeps only the library's cover and banner on disk, so these come from Steam's public store API. The
/// request names the game's app id and nothing else: no account, no Mac, nothing about the player.
///
/// The list and the small pictures are kept in `Artwork/steam-<id>`, so the page shows them at once and offline;
/// the list is asked again after a week. Full-size pictures are fetched only when the player opens one.
public enum SteamScreenshots {
    public struct Shot: Codable, Sendable, Equatable, Identifiable {
        public var id: Int
        /// 600×338.
        public var thumbnail: URL
        /// 1920×1080.
        public var full: URL
    }

    static let maxAge: TimeInterval = 7 * 24 * 3600

    static func request(appID: String) -> URL? {
        guard appID.allSatisfy(\.isNumber), !appID.isEmpty else { return nil }
        return URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&filters=screenshots")
    }

    /// `{"242920":{"success":true,"data":{"screenshots":[{"id":0,"path_thumbnail":"https://…","path_full":…}]}}}`.
    /// Pictures from anywhere but Steam's own servers are dropped.
    static func parse(_ data: Data, appID: String) -> [Shot]? {
        struct Entry: Decodable {
            var success: Bool
            var data: Details?
        }
        struct Details: Decodable { var screenshots: [Item]? }
        struct Item: Decodable {
            var id: Int
            var path_thumbnail: String // swiftlint:disable:this identifier_name
            var path_full: String // swiftlint:disable:this identifier_name
        }
        guard let entry = (try? JSONDecoder().decode([String: Entry].self, from: data))?[appID], entry.success
        else { return nil }
        return (entry.data?.screenshots ?? []).compactMap { item in
            guard let thumbnail = URL(string: item.path_thumbnail), let full = URL(string: item.path_full),
                  isSteams(thumbnail), isSteams(full) else { return nil }
            return Shot(id: item.id, thumbnail: thumbnail, full: full)
        }
    }

    static func isSteams(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return ["steamstatic.com", "steampowered.com", "akamaihd.net"]
            .contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func folder(appID: String, paths: AppPaths) -> URL {
        paths.artwork.appending(path: "steam-\(appID)", directoryHint: .isDirectory)
    }

    /// The list kept from last time, however old.
    public static func cached(appID: String, paths: AppPaths) -> [Shot]? {
        let file = folder(appID: appID, paths: paths).appending(path: "screenshots.json")
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Shot].self, from: $0) }
    }

    /// The game's screenshots: kept ones while fresh, otherwise asked from Steam (kept ones when that fails).
    public static func load(appID: String, paths: AppPaths, now: Date = Date()) async -> [Shot] {
        let file = folder(appID: appID, paths: paths).appending(path: "screenshots.json")
        let kept = cached(appID: appID, paths: paths)
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let kept, let modified, now.timeIntervalSince(modified) < maxAge { return kept }
        guard let url = request(appID: appID),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let shots = parse(data, appID: appID) else { return kept ?? [] }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(shots).write(to: file, options: .atomic)
        return shots
    }

    /// The small picture on disk, fetched the first time.
    public static func thumbnail(_ shot: Shot, appID: String, paths: AppPaths) async -> URL? {
        await picture(shot.thumbnail, appID: appID, paths: paths)
    }

    /// The full picture on disk, fetched the first time it is opened.
    public static func full(_ shot: Shot, appID: String, paths: AppPaths) async -> URL? {
        await picture(shot.full, appID: appID, paths: paths)
    }

    private static func picture(_ url: URL, appID: String, paths: AppPaths) async -> URL? {
        guard isSteams(url) else { return nil }
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = folder(appID: appID, paths: paths).appending(path: name + ".jpg")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return file
    }
}
