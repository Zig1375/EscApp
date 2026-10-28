import Foundation

extension Store {
    public static let epic = Store(EpicStore())
}

/// The Epic Games Launcher: a Windows Installer package, then its first start downloads its current version
/// (`StoreClient.updateEpic`). Games start through `com.epicgames.launcher://apps/` links; it records them in a
/// JSON `.item` per game.
struct EpicStore: StoreModule {
    let id = "epic"
    let name = "Epic Games Store"
    let bottleNumber: UInt8 = 2

    var installer: StoreInstaller {
        let link = "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/"
            + "EpicGamesLauncherInstaller.msi"
        // swiftlint:disable:next force_unwrapping
        return StoreInstaller(url: URL(string: link)!, arguments: ["/qn"], isPackage: true)
    }

    /// The package installs into the 64-bit Program Files of a 64-bit Windows.
    let clientPaths = ["Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe",
                       "Program Files (x86)/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe"]
    let clientFolders = [#"C:\Program Files\Epic Games\Launcher"#, #"C:\Program Files (x86)\Epic Games\Launcher"#,
                         #"C:\Program Files (x86)\Epic Games\Epic Online Services"#]

    /// The launcher draws its window with Unreal's OpenGL renderer: with its default Direct3D one the store
    /// pages never appear over the Epic logo, since Chromium's GPU process can't start in Wine ("Failed to
    /// launch GPU process" in cef3.log). No prerequisite installers at each start either.
    func clientArguments(clientReady: Bool) -> [String] { ["-opengl", "-SkipBuildPatchPrereq"] }

    func playArguments(storeID: String) -> [String] {
        ["com.epicgames.launcher://apps/\(storeID.replacingOccurrences(of: ":", with: "%3A"))"
            + "?action=launch&silent=true"]
    }

    func finishInstall(_ stores: StoreClient, client: URL, wine: Wine, environment: [String: String],
                       progress: @escaping @Sendable (StoreClient.Step) -> Void) async throws {
        progress(.updating(received: nil, total: nil))
        try await stores.updateEpic(client, wine: wine, environment: environment)
    }

    func prepareToStart(_ stores: StoreClient, bottle: URL, wine: Wine) async {
        if StoreClient.epicHasStagedUpdate(bottle) { await stores.applyEpicUpdate(wine: wine, in: bottle) }
    }

    func opened(_ stores: StoreClient, client: URL, wine: Wine) {
        stores.watchEpicUpdates(client, wine: wine)
    }

    /// The launcher saves the player's sign-in only when it exits by itself. Ended with the rest of its bottle
    /// (`wineserver -k`), it kept the token from before, which Epic's server refused at the next start
    /// (`invalid_grant`), so the player was signed out every time. `taskkill` without `/F` sends its window
    /// `WM_CLOSE`, as its close button does, and the launcher exited properly 3 s later (`LogExit: Exiting.`).
    /// `wineboot --end-session` and `SIGINT` ended it without that.
    ///
    /// Signed in, the launcher doesn't exit on `WM_CLOSE`: it goes to the tray, as on Windows, and EscApp waited
    /// the whole 20 s for nothing before ending it, so a launcher the player closed lingered half a minute. Its
    /// log says so at once ("Application is being minimized"), and then it is ended straight away. Its sign-in
    /// survives that now: signed in again after it was ended so on Wine 11.20 build 9. Nothing outside quits
    /// it from the tray: `WM_QUERYENDSESSION` and `WM_ENDSESSION` to its windows were ignored.
    func askToQuit(_ stores: StoreClient, client: URL, bottle: URL, wine: Wine,
                   environment: [String: String]) async {
        guard WineProcesses.running(in: bottle).contains(where: Self.isLauncher) else { return }
        let logs = StoreClient.epicLogs(in: bottle)
        let sizes = logs.map { (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }
        _ = try? await ProcessRunner.run(wine.wine.path, ["taskkill", "/IM", "EpicGamesLauncher.exe"],
                                         environment: environment, timeout: 10)
        let deadline = Date().addingTimeInterval(20)
        while WineProcesses.running(in: bottle).contains(where: Self.isLauncher), Date() < deadline {
            if zip(logs, sizes).contains(where: { StoreClient.epicWentToTray(Self.appended(to: $0, after: $1)) }) {
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// What `file` gained past its first `size` bytes.
    static func appended(to file: URL, after size: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return Data() }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(size))
        return (try? handle.readToEnd()) ?? Data()
    }

    static func isLauncher(_ process: WineProcesses.Process) -> Bool {
        let name = process.program.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last ?? ""
        return name.lowercased() == "epicgameslauncher.exe"
    }

    // MARK: Library

    struct Item: Decodable {
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

    static func manifests(_ bottle: URL) -> URL {
        bottle.appending(path: "drive_c/ProgramData/Epic/EpicGamesLauncher/Data/Manifests", directoryHint: .isDirectory)
    }

    func games(bottle: URL) -> [StoreLibrary.Game] {
        let manifests = Self.manifests(bottle)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: manifests.path)) ?? []
        return names.filter { $0.hasSuffix(".item") }.compactMap { name in
            (try? Data(contentsOf: manifests.appending(path: name))).flatMap { Self.game(item: $0, bottle: bottle) }
        }
    }

    /// A game's `.item`. Its launch id is `namespace:item:app`, the form the launcher's `apps/` links take.
    static func game(item data: Data, bottle: URL) -> StoreLibrary.Game? {
        guard let item = try? JSONDecoder().decode(Item.self, from: data), item.incomplete != true,
              let folder = WindowsPath.macURL(for: item.installLocation, bottle: bottle) else { return nil }
        var id = item.appName
        if let namespace = item.catalogNamespace, let catalogItem = item.catalogItemID,
           !namespace.isEmpty, !catalogItem.isEmpty {
            id = "\(namespace):\(catalogItem):\(item.appName)"
        }
        let exe = item.launchExecutable.flatMap { $0.isEmpty ? nil : $0 }.map {
            folder.appending(path: $0.replacingOccurrences(of: "\\", with: "/"))
        }
        return StoreLibrary.Game(store: .epic, id: id, name: item.displayName, folder: folder, executable: exe)
    }

    /// The catalog namespace of a launch id (`namespace:item:app`); a bare app name has none.
    static func namespace(storeID: String) -> String? { catalogIDs(storeID: storeID)?.namespace }

    static func catalogItem(storeID: String) -> String? { catalogIDs(storeID: storeID)?.item }

    private static func catalogIDs(storeID: String) -> (namespace: String, item: String)? {
        let parts = storeID.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, isCatalogID(parts[0]), isCatalogID(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    /// Mostly 32 hex digits, but Epic's own games have short names (`fn`, `crab`). They go into file names and URLs.
    static func isCatalogID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    // MARK: Uninstall

    let removesGamesWithoutClient = true

    /// The game's `.item` in the Manifests folder, and its `.egi` in Epic Online Services' InstallHelper. The
    /// launcher writes the `.item` back from the `.egi` at its next start: Before We Leave, deleted in EscApp,
    /// was in the list again after Epic restarted, pointing at a folder in the Trash.
    func records(ofGame id: String, folder: URL, bottle: URL) -> [URL] {
        let manifests = Self.manifests(bottle)
        let appName = Self.appName(id)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: manifests.path)) ?? []
        let items = names.filter { $0.hasSuffix(".item") }.map { manifests.appending(path: $0) }.filter { file in
            (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Item.self, from: $0) }?
                .appName == appName
        }
        let helper = Self.installHelperItems(bottle)
        let installs = ((try? FileManager.default.contentsOfDirectory(atPath: helper.path)) ?? [])
            .filter { $0.hasSuffix(".egi") }.map { helper.appending(path: $0) }
            .filter { file in (try? Data(contentsOf: file)).map { Self.installHelperItem($0, is: id) } ?? false }
        return items + installs
    }

    static func installHelperItems(_ bottle: URL) -> URL {
        bottle.appending(path: "drive_c/ProgramData/Epic/EpicOnlineServices/InstallHelper/InstalledItems",
                         directoryHint: .isDirectory)
    }

    /// An `.egi`: `{"v4": {"sandboxId": …, "itemId": …, "artifactId": …}}`, the parts of EscApp's Epic id.
    static func installHelperItem(_ data: Data, is id: String) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let install = json.values.compactMap({ $0 as? [String: Any] }).first,
              let artifact = install["artifactId"] as? String, artifact == appName(id) else { return false }
        let parts = id.split(separator: ":").map(String.init)
        guard parts.count == 3 else { return true }
        return install["sandboxId"] as? String == parts[0] && install["itemId"] as? String == parts[1]
    }

    func forgetGame(_ id: String, bottle: URL) throws {
        try Self.removeFromList(appName: Self.appName(id), bottle: bottle)
    }

    /// EscApp's Epic id is `namespace:item:app`; the launcher's records use the app part.
    static func appName(_ id: String) -> String {
        id.split(separator: ":").last.map(String.init) ?? id
    }

    /// The launcher's own list of installs, `LauncherInstalled.dat`: `{"InstallationList": [{"AppName": …}]}`.
    static func removeFromList(appName: String, bottle: URL) throws {
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
