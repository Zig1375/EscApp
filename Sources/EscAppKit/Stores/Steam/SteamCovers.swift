import Foundation

/// A Steam game's portrait cover (600×900), for its card in the library. Steam keeps the covers of the account's
/// games in its own `appcache/librarycache`, so nothing is fetched: the card shows what Steam already downloaded.
public enum SteamCovers {
    static let fileName = "library_600x900.jpg"

    /// `<appid>/library_600x900.jpg`, or in a folder named by the picture's hash below it (Steam does that for some
    /// games, Half-Life 2's among them: `220/<hash>/`). Older clients kept them flat, as
    /// `<appid>_library_600x900.jpg`.
    public static func cover(appID: String, steamFolder: URL) -> URL? {
        guard appID.allSatisfy(\.isNumber), !appID.isEmpty else { return nil }
        let cache = steamFolder.appending(path: "appcache/librarycache", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        let folder = cache.appending(path: appID, directoryHint: .isDirectory)
        let direct = folder.appending(path: fileName)
        if fileManager.fileExists(atPath: direct.path) { return direct }
        let nested = ((try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appending(path: fileName) }
            .filter { fileManager.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
        if let first = nested.first { return first }
        let flat = cache.appending(path: "\(appID)_\(fileName)")
        return fileManager.fileExists(atPath: flat.path) ? flat : nil
    }

    /// Steam's folder in its bottle.
    public static func steamFolder(bottle: URL) -> URL {
        bottle.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
    }
}
