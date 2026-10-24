import Foundation

/// "Delete" on a store game, without opening the store: the game's folder goes to the Trash and the store's own
/// record of it is removed, so the store shows it as not installed. Only for stores that record their games in
/// files (Steam, Epic); the registry-based ones (GOG Galaxy, EA app, Ubisoft Connect) remove their games
/// themselves.
public enum StoreUninstall {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notFound(String)

        public var description: String {
            switch self {
            case let .notFound(name): "\(name) isn't installed where its store says it is."
            }
        }
    }

    public static func canRemove(_ store: Store) -> Bool { store == .steam || store == .epic }

    /// Moves the game's folder to the Trash and drops the store's record of it. The game must not be running.
    /// - Parameter trash: moves the folder to the Trash; tests delete it instead.
    public static func remove(_ game: GameRecord, paths: AppPaths, trash: (URL) throws -> Void = moveToTrash) throws {
        guard let store = game.store, let id = game.storeID, canRemove(store) else { return }
        let bottle = paths.bottle(forGame: store.bottleID)
        let folder = URL(filePath: game.folder, directoryHint: .isDirectory)
        let records = store == .steam ? steamRecords(appID: id, folder: folder)
            : epicRecords(id: id, bottle: bottle)
        guard !records.isEmpty || FileManager.default.fileExists(atPath: folder.path) else {
            throw Failure.notFound(game.name)
        }
        if FileManager.default.fileExists(atPath: folder.path) {
            try trash(folder)
        }
        for record in records { try? FileManager.default.removeItem(at: record) }
        if store == .epic { try? removeFromEpicList(appName: epicAppName(id), bottle: bottle) }
        _ = try StoreLibrary.sync(paths: paths)
    }

    public static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// `steamapps/appmanifest_<id>.acf` next to `common/<game>`, and its workshop record if it has one.
    static func steamRecords(appID: String, folder: URL) -> [URL] {
        let steamapps = folder.deletingLastPathComponent().deletingLastPathComponent()
        return [steamapps.appending(path: "appmanifest_\(appID).acf"),
                steamapps.appending(path: "workshop/appworkshop_\(appID).acf")]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The game's `.item` in Epic's Manifests folder.
    static func epicRecords(id: String, bottle: URL) -> [URL] {
        let manifests = bottle.appending(path: "drive_c/ProgramData/Epic/EpicGamesLauncher/Data/Manifests",
                                         directoryHint: .isDirectory)
        let appName = epicAppName(id)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: manifests.path)) ?? []
        return names.filter { $0.hasSuffix(".item") }.map { manifests.appending(path: $0) }.filter { file in
            (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(StoreLibrary.EpicItem.self, from: $0) }?
                .appName == appName
        }
    }

    /// EscApp's Epic id is `namespace:item:app`; the launcher's records use the app part.
    static func epicAppName(_ id: String) -> String {
        id.split(separator: ":").last.map(String.init) ?? id
    }

    /// The launcher's own list of installs, `LauncherInstalled.dat`: `{"InstallationList": [{"AppName": …}]}`.
    static func removeFromEpicList(appName: String, bottle: URL) throws {
        let file = bottle.appending(path: "drive_c/ProgramData/Epic/UnrealEngineLauncher/LauncherInstalled.dat")
        let data = try Data(contentsOf: file)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["InstallationList"] as? [[String: Any]] else { return }
        let kept = list.filter { $0["AppName"] as? String != appName }
        guard kept.count != list.count else { return }
        json["InstallationList"] = kept
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]).write(to: file, options: .atomic)
    }
}
