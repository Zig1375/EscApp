import Foundation

/// A Steam game's screenshots, from Steam's public store API (`StoreScreenshots` keeps them).
public enum SteamScreenshots {
    static func request(appID: String) -> URL? {
        guard appID.allSatisfy(\.isNumber), !appID.isEmpty else { return nil }
        return URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&filters=screenshots")
    }

    static func fetch(appID: String) async -> [StoreScreenshots.Shot]? {
        guard let url = request(appID: appID),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data, appID: appID)
    }

    /// `{"242920":{"success":true,"data":{"screenshots":[{"id":0,"path_thumbnail":"https://…","path_full":…}]}}}`.
    /// Pictures from anywhere but Steam's own servers are dropped.
    static func parse(_ data: Data, appID: String) -> [StoreScreenshots.Shot]? {
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
            return .init(id: item.id, thumbnail: thumbnail, full: full)
        }
    }

    static func isSteams(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return ["steamstatic.com", "steampowered.com", "akamaihd.net"]
            .contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
