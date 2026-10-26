import Darwin
import Foundation

extension Store {
    public static let steam = Store(SteamStore())
}

/// Steam: installed silently, then its first start downloads the client itself (`StoreClient.updateSteam`).
/// Games start with `-applaunch <id>`; it records them in `appmanifest_<id>.acf` files in each library folder.
struct SteamStore: StoreModule {
    let id = "steam"
    let name = "Steam"
    let bottleNumber: UInt8 = 1

    var installer: StoreInstaller {
        StoreInstaller(url: URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!,
                       arguments: ["/S"])
    }

    let clientPaths = ["Program Files (x86)/Steam/steam.exe"]
    let clientFolders = [#"C:\Program Files (x86)\Steam"#, #"C:\Program Files (x86)\Common Files\Steam"#]
    let gameFolders = [#"C:\Program Files (x86)\Steam\steamapps"#]
    /// Its web helper moves between client versions (`bin/cef/cef.win7x64`, `cef.win64`).
    let chromiumHelpers = ["Program Files (x86)/Steam/bin/cef/*/steamwebhelper.exe"]

    /// Steam checks its files at every start and puts its own web helper back over `ChromiumHelper`'s, which
    /// leaves its window black. Before its first update there is nothing to check.
    func clientArguments(clientReady: Bool) -> [String] {
        ["-no-cef-sandbox"] + (clientReady ? ["-noverifyfiles"] : [])
    }

    func playArguments(storeID: String) -> [String] { ["-silent", "-applaunch", storeID] }

    /// Steam has a link for removing a game; other clients open on their library, where the game is removed.
    func uninstallArguments(storeID: String) -> [String] { ["steam://uninstall/\(storeID)"] }

    func isReady(bottle: URL) -> Bool { StoreClient.steamReady(bottle) }

    /// A game Steam is getting ready, or downloading: quitting it would cancel either.
    func isBusy(bottle: URL) -> Bool {
        SteamLaunches.inProgress(in: bottle) || SteamDownloads.inProgress(in: bottle)
    }

    func finishInstall(_ stores: StoreClient, client: URL, wine: Wine, environment: [String: String],
                       progress: @escaping @Sendable (StoreClient.Step) -> Void) async throws {
        let bottle = stores.bottle(for: .steam)
        guard !StoreClient.steamReady(bottle) else { return }
        progress(.updating(received: nil, total: nil))
        try await stores.updateSteam(client, wine: wine, environment: environment, in: bottle, progress: progress)
    }

    /// Fresh from its own installer, Steam first downloads its client: its web helper arrives with it, and would
    /// run unwrapped, black, the first time.
    func prepareInstalledByPlayer(_ stores: StoreClient, client: URL, bottle: URL, wine: Wine) async throws {
        guard !StoreClient.steamReady(bottle) else { return }
        let environment = WineEnvironment.make(host: stores.host, bottle: bottle.path,
                                               fastSync: WineEnvironment.fastSync(for: nil, wine: wine))
        try await stores.updateSteam(client, wine: wine, environment: environment, in: bottle) { _ in }
    }

    /// Steam is asked to quit first, so it saves its state. A Steam stuck at start never answers `-shutdown`:
    /// after 20 s the rest of the bottle is ended anyway.
    func askToQuit(_ stores: StoreClient, client: URL, bottle: URL, wine: Wine,
                   environment: [String: String]) async {
        _ = try? await ProcessRunner.run(wine.wine.path, [client.path(percentEncoded: false), "-shutdown"],
                                         environment: environment, timeout: 20)
        let deadline = Date().addingTimeInterval(20)
        while !WineProcesses.running(in: bottle).isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    func tidy(_ processes: [WineProcesses.Process]) {
        for pid in SteamHelperSweep.strays(SteamHelperSweep.helpers(in: processes)) { kill(pid, SIGKILL) }
    }

    // MARK: Library

    /// Steam's own tools and runtimes, which it installs like games.
    static let tools: Set<String> = ["228980"]  // Steamworks Common Redistributables

    func games(bottle: URL) -> [StoreLibrary.Game] {
        let steam = bottle.appending(path: "drive_c/Program Files (x86)/Steam", directoryHint: .isDirectory)
        var folders = [steam.appending(path: "steamapps", directoryHint: .isDirectory)]
        let list = steam.appending(path: "steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: list, encoding: .utf8) {
            for path in Self.libraryPaths(ValveKeyValues.parse(text)) {
                if let url = WindowsPath.macURL(for: path, bottle: bottle) {
                    folders.append(url.appending(path: "steamapps", directoryHint: .isDirectory))
                }
            }
        }
        var seen = Set<String>()
        var games: [StoreLibrary.Game] = []
        for folder in folders where seen.insert(folder.standardized.path.lowercased()).inserted {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
                guard let text = try? String(contentsOf: folder.appending(path: name), encoding: .utf8),
                      let game = Self.game(manifest: text, steamapps: folder) else { continue }
                games.append(game)
            }
        }
        return games
    }

    /// `libraryfolders.vdf`: `"libraryfolders" { "0" { "path" "C:\\Program Files (x86)\\Steam" … } … }`.
    static func libraryPaths(_ file: ValveKeyValues) -> [String] {
        (file["libraryfolders"]?.entries ?? []).compactMap { $0.1["path"]?.string }
    }

    /// One `appmanifest_<id>.acf`. Only fully installed games: bit 4 of `StateFlags` (a game being downloaded
    /// or updated has other bits as well, but keeps 4 once it was installed).
    static func game(manifest text: String, steamapps: URL) -> StoreLibrary.Game? {
        guard let state = ValveKeyValues.parse(text)["AppState"], let id = state["appid"]?.string,
              let name = state["name"]?.string, let folder = state["installdir"]?.string,
              !tools.contains(id), (Int(state["StateFlags"]?.string ?? "") ?? 0) & 4 != 0 else { return nil }
        return StoreLibrary.Game(store: .steam, id: id, name: name,
                                 folder: steamapps.appending(path: "common/\(folder)", directoryHint: .isDirectory))
    }

    /// A Steam game whose `appmanifest_<id>.acf` and folder are both there is installed, even when the scan
    /// couldn't read the manifest: Steam rewrites it while it updates the game, and a read meanwhile dropped
    /// Banished from the list and added it again under a new id, without its play time and settings.
    /// A game Steam (or "Delete") uninstalled loses its manifest.
    func stillInstalled(_ record: GameRecord) -> Bool {
        guard let id = record.storeID else { return false }
        let folder = URL(filePath: record.folder, directoryHint: .isDirectory)
        let steamapps = folder.deletingLastPathComponent().deletingLastPathComponent()
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: folder.path)
            && fileManager.fileExists(atPath: steamapps.appending(path: "appmanifest_\(id).acf").path)
    }

    // MARK: Uninstall

    let removesGamesWithoutClient = true

    /// `steamapps/appmanifest_<id>.acf` next to `common/<game>`, and its workshop record if it has one.
    func records(ofGame id: String, folder: URL, bottle: URL) -> [URL] {
        let steamapps = folder.deletingLastPathComponent().deletingLastPathComponent()
        return [steamapps.appending(path: "appmanifest_\(id).acf"),
                steamapps.appending(path: "workshop/appworkshop_\(id).acf")]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
