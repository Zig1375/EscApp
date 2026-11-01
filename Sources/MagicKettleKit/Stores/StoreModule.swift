import Foundation

/// Everything Magic Kettle knows about one store's Windows client: where it is, how it installs and starts, where it
/// records its games and how it starts them. `Store` is only the store's name in `Games.json`; the knowledge is
/// here, a folder per store (`Stores/Steam`, `Stores/Epic`). Adding a store is a type conforming to this and its
/// line in `Store.allCases`; what most clients do alike has defaults below.
protocol StoreModule: Sendable {
    /// Its name in `Games.json` and on the command line. Fixed once a store shipped.
    var id: String { get }
    var name: String { get }
    /// The last byte of the store's bottle id (`Store.bottleID`). Fixed once a store shipped, and never reused:
    /// 1 is Steam, 2 Epic, 3 to 5 were GOG Galaxy, the EA app and Ubisoft Connect, which earlier versions had.
    var bottleNumber: UInt8 { get }

    /// The publisher's own installer (`StoreInstaller`).
    var installer: StoreInstaller { get }
    /// Where the client is in the bottle's `drive_c`, newest layout first.
    var clientPaths: [String] { get }
    /// Windows folders of the client and its services. A program anywhere else in the bottle is a game, apart
    /// from Windows' own.
    var clientFolders: [String] { get }
    /// Where the client puts its games inside its own folder.
    var gameFolders: [String] { get }
    /// Chromium helpers that draw the client's window, relative to `drive_c` (`ChromiumHelper`). A `*` stands
    /// for one folder name.
    var chromiumHelpers: [String] { get }

    /// Whether the client's window is drawn at the screen's full resolution on a Retina display: Wine's Retina
    /// mode and the DPI to match (`StoreClient.drawSharp`). False for a client whose own windows are drawn at a
    /// fixed pixel size: in Retina mode they come out at half the size of the rest of its interface.
    var drawsAtScreenResolution: Bool { get }

    /// What the client and its games get in their environment. Launchers that embed Qt WebEngine (CD Projekt's,
    /// Ubisoft's) are a Chromium too, and drew nothing with GPU compositing, like Steam's own window.
    var environment: [String: String] { get }

    /// What opens the client's window, and goes before `playArguments` when it starts a game.
    func clientArguments(clientReady: Bool) -> [String]
    /// Whether games start through the client, which handles the account and DRM.
    var launchesGames: Bool { get }
    /// What asks the running client to start a game; it starts the client first if it isn't running.
    func playArguments(storeID: String) -> [String]
    /// What opens the client on removing one of its games.
    func uninstallArguments(storeID: String) -> [String]

    /// The games installed in `bottle`, read from the store's own records.
    func games(bottle: URL) -> [StoreLibrary.Game]
    /// A game the scan missed that is still installed all the same; it stays in the library.
    func stillInstalled(_ record: GameRecord) -> Bool
    /// Whether "Delete" can remove one of its games without the client (`StoreUninstall`): the store records its
    /// games in files Magic Kettle can put in the Trash.
    var removesGamesWithoutClient: Bool { get }
    /// The store's own files about one game, which go to the Trash with its folder.
    func records(ofGame id: String, folder: URL, bottle: URL) -> [URL]
    /// Anything else that names the game as installed, once its folder and records are gone.
    func forgetGame(_ id: String, bottle: URL) throws

    /// Whether the client in `bottle` is complete enough to start normally.
    func isReady(bottle: URL) -> Bool
    /// The client is in the middle of something that quitting it would break, with no game process running.
    func isBusy(bottle: URL) -> Bool
    /// What the client waits for the player to answer in its own window before it starts the game `storeID`, if
    /// anything.
    func question(bottle: URL, storeID: String) -> String?
    /// After its installer: what the client needs before its first "Open".
    func finishInstall(_ stores: StoreClient, client: URL, wine: Wine, environment: [String: String],
                       progress: @escaping @Sendable (StoreClient.Step) -> Void) async throws
    /// Before the client starts in Magic Kettle's bottle for it, while nothing runs there.
    func prepareToStart(_ stores: StoreClient, bottle: URL, wine: Wine) async
    /// Before the client starts in a bottle of its own, installed by the player with the store's installer
    /// (`StoreClient.prepareClientProgram`), while nothing runs there.
    func prepareInstalledByPlayer(_ stores: StoreClient, client: URL, bottle: URL, wine: Wine) async throws
    /// Right after "Open" started the client.
    func opened(_ stores: StoreClient, client: URL, wine: Wine)
    /// Asks the running client to quit by itself before its bottle's Wine is ended, and waits for it.
    func askToQuit(_ stores: StoreClient, client: URL, bottle: URL, wine: Wine, environment: [String: String]) async
    /// One look at the client's processes while it runs (`StoreKeeper`).
    func tidy(_ processes: [WineProcesses.Process])
}

/// A store's installer, always its newest version. Stores replace these files with every release, so they can't
/// be pinned by checksum like the runtime; Magic Kettle takes them only over HTTPS from the publisher, checks that the
/// file is a Windows program before running it, and runs it inside the store's own bottle.
struct StoreInstaller: Sendable {
    var url: URL
    /// What makes it run without asking; an installer without them shows its own window, which the player follows.
    var arguments: [String]
    /// A Windows Installer package, run with `msiexec`, rather than a program.
    var isPackage = false
}

extension StoreModule {
    var gameFolders: [String] { [] }
    var chromiumHelpers: [String] { [] }
    var drawsAtScreenResolution: Bool { true }
    var environment: [String: String] { [:] }
    func clientArguments(clientReady: Bool) -> [String] { [] }
    var launchesGames: Bool { true }
    func uninstallArguments(storeID: String) -> [String] { [] }

    func stillInstalled(_ record: GameRecord) -> Bool { false }
    var removesGamesWithoutClient: Bool { false }
    func records(ofGame id: String, folder: URL, bottle: URL) -> [URL] { [] }
    func forgetGame(_ id: String, bottle: URL) throws {}

    func isReady(bottle: URL) -> Bool { true }
    func isBusy(bottle: URL) -> Bool { false }
    func question(bottle: URL, storeID: String) -> String? { nil }
    func finishInstall(_ stores: StoreClient, client: URL, wine: Wine, environment: [String: String],
                       progress: @escaping @Sendable (StoreClient.Step) -> Void) async throws {}
    func prepareToStart(_ stores: StoreClient, bottle: URL, wine: Wine) async {}
    func prepareInstalledByPlayer(_ stores: StoreClient, client: URL, bottle: URL, wine: Wine) async throws {
        await prepareToStart(stores, bottle: bottle, wine: wine)
    }
    func opened(_ stores: StoreClient, client: URL, wine: Wine) {}
    func askToQuit(_ stores: StoreClient, client: URL, bottle: URL, wine: Wine,
                   environment: [String: String]) async {}
    func tidy(_ processes: [WineProcesses.Process]) {}
}
