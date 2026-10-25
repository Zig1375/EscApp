import Foundation

/// The games each store has installed in its bottle, read from the store's own records, and kept in `Games.json`
/// so they show in the library like any other game ("Steam games appear in EscApp by themselves").
///
/// Each store records its games its own way: Steam in `appmanifest_<id>.acf` files in each library folder, Epic
/// in a JSON `.item` per game, GOG Galaxy and Ubisoft Connect in the registry, the EA app in an installer file
/// in each game's folder. Reading them is pure file parsing, tested without Wine.
public enum StoreLibrary {
    /// One installed game, as its store records it.
    public struct Game: Sendable, Equatable {
        public var store: Store
        public var id: String
        public var name: String
        public var folder: URL
        /// The program the store says starts the game, when it says so (Epic, GOG). Otherwise EscApp picks one
        /// from the folder, for the icon and to tell which DirectX the game uses.
        public var executable: URL?
    }

    public static func games(of store: Store, bottle: URL) -> [Game] {
        switch store {
        case .steam: steamGames(bottle: bottle)
        case .epic: epicGames(bottle: bottle)
        case .gog: gogGames(bottle: bottle)
        case .eaApp: eaGames(bottle: bottle)
        case .ubisoft: ubisoftGames(bottle: bottle)
        }
    }

    // MARK: Steam

    /// Steam's own tools and runtimes, which it installs like games.
    static let steamTools: Set<String> = ["228980"]  // Steamworks Common Redistributables

    static func steamGames(bottle: URL) -> [Game] {
        let steam = bottle.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        var folders = [steam.appending(path: "steamapps", directoryHint: .isDirectory)]
        let list = steam.appending(path: "steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: list, encoding: .utf8) {
            for path in steamLibraryPaths(ValveKeyValues.parse(text)) {
                if let url = WindowsPath.macURL(for: path, bottle: bottle) {
                    folders.append(url.appending(path: "steamapps", directoryHint: .isDirectory))
                }
            }
        }
        var seen = Set<String>()
        var games: [Game] = []
        for folder in folders where seen.insert(folder.standardized.path.lowercased()).inserted {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
                guard let text = try? String(contentsOf: folder.appending(path: name), encoding: .utf8),
                      let game = steamGame(manifest: text, steamapps: folder) else { continue }
                games.append(game)
            }
        }
        return games
    }

    /// `libraryfolders.vdf`: `"libraryfolders" { "0" { "path" "C:\\Program Files (x86)\\Steam" … } … }`.
    static func steamLibraryPaths(_ file: ValveKeyValues) -> [String] {
        (file["libraryfolders"]?.entries ?? []).compactMap { $0.1["path"]?.string }
    }

    /// One `appmanifest_<id>.acf`. Only fully installed games: bit 4 of `StateFlags` (a game being downloaded
    /// or updated has other bits as well, but keeps 4 once it was installed).
    static func steamGame(manifest text: String, steamapps: URL) -> Game? {
        guard let state = ValveKeyValues.parse(text)["AppState"], let id = state["appid"]?.string,
              let name = state["name"]?.string, let folder = state["installdir"]?.string,
              !steamTools.contains(id), (Int(state["StateFlags"]?.string ?? "") ?? 0) & 4 != 0 else { return nil }
        return Game(store: .steam, id: id, name: name,
                    folder: steamapps.appending(path: "common/\(folder)", directoryHint: .isDirectory))
    }

    // MARK: Epic

    struct EpicItem: Decodable {
        var displayName: String
        var installLocation: String
        var launchExecutable: String?
        var appName: String
        var catalogNamespace: String?
        var catalogItemID: String?
        var incomplete: Bool?

        enum CodingKeys: String, CodingKey {
            case displayName = "DisplayName", installLocation = "InstallLocation"
            case launchExecutable = "LaunchExecutable", appName = "AppName"
            case catalogNamespace = "CatalogNamespace", catalogItemID = "CatalogItemId"
            case incomplete = "bIsIncompleteInstall"
        }
    }

    static func epicGames(bottle: URL) -> [Game] {
        let manifests = bottle.appending(path: "drive_c/ProgramData/Epic/EpicGamesLauncher/Data/Manifests",
                                         directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: manifests.path)) ?? []
        return names.filter { $0.hasSuffix(".item") }.compactMap { name in
            (try? Data(contentsOf: manifests.appending(path: name))).flatMap { epicGame(item: $0, bottle: bottle) }
        }
    }

    /// A game's `.item`. Its launch id is `namespace:item:app`, the form the launcher's `apps/` links take.
    static func epicGame(item data: Data, bottle: URL) -> Game? {
        guard let item = try? JSONDecoder().decode(EpicItem.self, from: data), item.incomplete != true,
              let folder = WindowsPath.macURL(for: item.installLocation, bottle: bottle) else { return nil }
        var id = item.appName
        if let namespace = item.catalogNamespace, let catalogItem = item.catalogItemID,
           !namespace.isEmpty, !catalogItem.isEmpty {
            id = "\(namespace):\(catalogItem):\(item.appName)"
        }
        let exe = item.launchExecutable.flatMap { $0.isEmpty ? nil : $0 }.map {
            folder.appending(path: $0.replacingOccurrences(of: "\\", with: "/"))
        }
        return Game(store: .epic, id: id, name: item.displayName, folder: folder, executable: exe)
    }

    // MARK: Registry stores

    /// Subkeys of `parent` in a registry file, with their values: `[(name, values)]`.
    static func subkeys(of parent: String, in text: String) -> [(String, [String: String])] {
        let prefix = parent.replacingOccurrences(of: "\\", with: "\\\\").lowercased() + "\\\\"
        return RegistryFile(text).keys.compactMap { key in
            let path = key.path.lowercased()
            guard path.hasPrefix(prefix) else { return nil }
            let name = String(key.path.dropFirst(prefix.count))
            guard !name.isEmpty, !name.contains("\\") else { return nil }
            var values: [String: String] = [:]
            let unescaped = key.path.replacingOccurrences(of: "\\\\", with: "\\")
            for value in key.values {
                let valueName = value.name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if let string = WineRegistry.string(in: "[\(key.path)]\n\(value.text)", key: unescaped,
                                                    name: valueName) {
                    values[valueName.lowercased()] = string
                }
            }
            return (name, values)
        }
    }

    /// GOG Galaxy writes `HKLM\Software\GOG.com\Games\<id>` with `gameName`, `path` and `exe`; its programs are
    /// 32-bit, so in a 64-bit bottle the key is under `Wow6432Node`.
    static func gogGames(bottle: URL) -> [Game] {
        let text = (try? String(contentsOf: bottle.appending(path: "system.reg"), encoding: .utf8)) ?? ""
        return gogGames(systemReg: text, bottle: bottle)
    }

    static func gogGames(systemReg text: String, bottle: URL) -> [Game] {
        [#"Software\Wow6432Node\GOG.com\Games"#, #"Software\GOG.com\Games"#].flatMap { parent in
            subkeys(of: parent, in: text).compactMap { id, values -> Game? in
                guard let name = values["gamename"], let path = values["path"],
                      let folder = WindowsPath.macURL(for: path, bottle: bottle) else { return nil }
                let exe = values["exe"].flatMap { WindowsPath.macURL(for: $0, bottle: bottle) }
                return Game(store: .gog, id: id, name: name, folder: folder, executable: exe)
            }
        }
    }

    /// Ubisoft Connect writes `HKLM\Software\Ubisoft\Launcher\Installs\<id>` with `InstallDir`.
    static func ubisoftGames(bottle: URL) -> [Game] {
        let text = (try? String(contentsOf: bottle.appending(path: "system.reg"), encoding: .utf8)) ?? ""
        return ubisoftGames(systemReg: text, bottle: bottle)
    }

    static func ubisoftGames(systemReg text: String, bottle: URL) -> [Game] {
        [#"Software\Wow6432Node\Ubisoft\Launcher\Installs"#, #"Software\Ubisoft\Launcher\Installs"#]
            .flatMap { parent in
                subkeys(of: parent, in: text).compactMap { id, values -> Game? in
                    guard let path = values["installdir"],
                          let folder = WindowsPath.macURL(for: path, bottle: bottle),
                          FileManager.default.fileExists(atPath: folder.path) else { return nil }
                    return Game(store: .ubisoft, id: id, name: folder.lastPathComponent, folder: folder)
                }
            }
    }

    // MARK: EA

    /// The EA app installs into `C:\Program Files\EA Games\<Game>`, each game with `__Installer\installerdata.xml`
    /// naming its content id, which the app's launch links take.
    static func eaGames(bottle: URL) -> [Game] {
        let root = bottle.appending(path: "drive_c/Program Files/EA Games", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        return ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []).compactMap { name in
            let folder = root.appending(path: name, directoryHint: .isDirectory)
            let data = folder.appending(path: "__Installer/installerdata.xml")
            guard let xml = try? String(contentsOf: data, encoding: .utf8) else { return nil }
            return Game(store: .eaApp, id: eaContentID(xml) ?? name, name: name, folder: folder)
        }
    }

    static func eaContentID(_ xml: String) -> String? {
        guard let start = xml.range(of: "<contentID>"),
              let end = xml.range(of: "</contentID>", range: start.upperBound..<xml.endIndex) else { return nil }
        let id = xml[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
}

extension StoreLibrary {
    /// Brings `Games.json` in line with what the stores have installed: new games are added, games a store
    /// uninstalled go, and a game keeps its id, play time and settings while it stays. Games from a store whose
    /// client was removed go too. Returns whether anything changed.
    @discardableResult
    public static func sync(paths: AppPaths, now: Date = Date()) throws -> Bool {
        var found: [Store: [Game]] = [:]
        for store in Store.allCases {
            let bottle = paths.bottle(forGame: store.bottleID)
            found[store] = store.client(in: bottle) == nil ? [] : games(of: store, bottle: bottle)
        }
        var steamApps: Set<String> = []
        let changed = try GameLibrary.modify(paths.library) { library in
            let changed = merge(found, into: &library, now: now, retina: SharedSettings.newGameRetina(paths: paths))
            steamApps = Set(library.games.filter { $0.store == .steam }.compactMap(\.storeID))
            return changed
        }
        SteamScreenshots.prune(keeping: steamApps, paths: paths)
        return changed
    }

    /// The pure part of `sync`.
    /// - Parameters:
    ///   - retina: the Retina setting a newly found game gets (`SharedSettings.newGameRetina`).
    ///   - stillThere: a game the scan missed that is still installed all the same; it stays.
    static func merge(_ found: [Store: [Game]], into library: inout GameLibrary, now: Date,
                      retina: GameScaling.Setting? = nil,
                      stillThere: (GameRecord) -> Bool = stillInstalled) -> Bool {
        var changed = false
        let before = library.games
        library.games.removeAll { record in
            guard let store = record.store else { return false }
            return !(found[store] ?? []).contains { $0.id == record.storeID } && !stillThere(record)
        }
        changed = library.games.count != before.count
        for (store, games) in found {
            for game in games {
                let existing = library.games.firstIndex { $0.store == store && $0.storeID == game.id }
                let folder = game.folder.path(percentEncoded: false)
                if let index = existing {
                    var record = library.games[index]
                    record.name = game.name
                    record.folder = folder
                    // A program the store names wins over one EscApp picked, and a picked one stays while it exists.
                    if let exe = game.executable?.path(percentEncoded: false), exe != record.executable {
                        record.executable = exe
                    } else if !FileManager.default.fileExists(atPath: record.executable),
                              let exe = mainProgram(of: game) {
                        record.executable = exe.path(percentEncoded: false)
                    }
                    if record != library.games[index] {
                        library.games[index] = record
                        changed = true
                    }
                } else if let exe = game.executable ?? mainProgram(of: game) {
                    var record = GameRecord(id: .make(), name: game.name, executable: exe.path(percentEncoded: false),
                                            folder: folder, hasMarker: false, addedAt: now)
                    record.store = store
                    record.storeID = game.id
                    record.retina = retina
                    library.games.append(record)
                    changed = true
                }
            }
        }
        return changed
    }

    /// A Steam game whose `appmanifest_<id>.acf` and folder are both there is installed, even when the scan
    /// couldn't read the manifest: Steam rewrites it while it updates the game, and a read meanwhile dropped
    /// Banished from the list and added it again under a new id, without its play time and settings.
    /// A game Steam (or "Delete") uninstalled loses its manifest. A store whose client was removed takes its
    /// games with it.
    static func stillInstalled(_ record: GameRecord) -> Bool {
        guard record.store == .steam, let id = record.storeID else { return false }
        let folder = URL(filePath: record.folder, directoryHint: .isDirectory)
        let steamapps = folder.deletingLastPathComponent().deletingLastPathComponent()
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: folder.path)
            && fileManager.fileExists(atPath: steamapps.appending(path: "appmanifest_\(id).acf").path)
    }

    /// The program that starts the game, picked like after an install: named like the game, else the biggest.
    static func mainProgram(of game: Game) -> URL? {
        let found = InstalledPrograms.find(in: [game.folder], shortcutTargets: [], name: game.name)
        return found.recommended?.url ?? found.programs.first?.url
    }
}
