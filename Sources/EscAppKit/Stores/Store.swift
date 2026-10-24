import Foundation

/// A game store whose Windows client EscApp can install (Stores.dc.html). Each lives in its own bottle, so a
/// store's client and its updates never touch other games. Its games run in that bottle too, started through the
/// client, which handles the account and DRM.
public enum Store: String, Codable, CaseIterable, Sendable, Identifiable {
    case steam, epic, gog
    case eaApp = "ea"
    case ubisoft

    public var id: Self { self }

    public var name: String {
        switch self {
        case .steam: "Steam"
        case .epic: "Epic Games Store"
        case .gog: "GOG Galaxy"
        case .eaApp: "EA app"
        case .ubisoft: "Ubisoft Connect"
        }
    }

    /// The store's bottle is named like a game's, so making it, moving it to a new runtime and resetting it
    /// work the same way. These ids are fixed and never made by `GameID.make()` (version 4 UUIDs are random).
    public var bottleID: GameID {
        let number = UInt8((Store.allCases.firstIndex(of: self) ?? 0) + 1)
        // E5CA5704-0000-4000-8000-00000000000<n>
        return GameID(uuid: UUID(uuid: (0xE5, 0xCA, 0x57, 0x04, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, number)))
    }

    /// The store whose bottle this is, for a bottle's id.
    public static func owning(bottle id: GameID) -> Store? {
        allCases.first { $0.bottleID == id }
    }

    /// The publisher's own installer, always its newest version. Stores replace these files with every release,
    /// so they can't be pinned by checksum like the runtime; EscApp takes them only over HTTPS from the
    /// publisher, checks that the file is a Windows program before running it, and runs it inside the store's
    /// own bottle.
    public var installerURL: URL {
        let link = switch self {
        case .steam: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"
        case .epic: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/"
            + "EpicGamesLauncherInstaller.msi"
        case .gog: "https://webinstallers.gog-statics.com/download/GOG_Galaxy_2.0.exe"
        case .eaApp: "https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe"
        case .ubisoft: "https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe"
        }
        // swiftlint:disable:next force_unwrapping
        return URL(string: link)!
    }

    /// Steam's and Ubisoft's installers run silently, Epic's is a Windows Installer package. GOG's and EA's
    /// show their own setup window, which the player follows.
    var installerArguments: [String] {
        switch self {
        case .steam, .ubisoft: ["/S"]
        case .epic: ["/qn"]
        case .gog, .eaApp: []
        }
    }

    var installerIsPackage: Bool { self == .epic }

    /// Where the client is in the bottle's `drive_c`, newest layout first.
    var clientPaths: [String] {
        switch self {
        case .steam: ["Program Files (x86)/Steam/steam.exe"]
        // Epic's package installs into the 64-bit Program Files of a 64-bit Windows.
        case .epic: ["Program Files/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe",
                     "Program Files (x86)/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe"]
        case .gog: ["Program Files (x86)/GOG Galaxy/GalaxyClient.exe"]
        case .eaApp: ["Program Files/Electronic Arts/EA Desktop/EA Desktop/EADesktop.exe"]
        case .ubisoft: ["Program Files (x86)/Ubisoft/Ubisoft Game Launcher/UbisoftConnect.exe"]
        }
    }

    /// The client in `bottle`, once installed.
    public func client(in bottle: URL) -> URL? {
        let drive = bottle.appending(path: "drive_c", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        if self == .eaApp, let newest = Self.newestEAClient(in: drive) { return newest }
        return clientPaths.map { drive.appending(path: $0) }.first { fileManager.fileExists(atPath: $0.path) }
    }

    /// The EA app keeps each version in `EA Desktop\<version>\EA Desktop\EADesktop.exe` and points a junction,
    /// `EA Desktop\EA Desktop`, at the newest. Wine leaves that junction an empty folder, so the newest version
    /// is found by its folder name.
    static func newestEAClient(in drive: URL) -> URL? {
        let root = drive.appending(path: "Program Files/Electronic Arts/EA Desktop", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        return ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [])
            .map { root.appending(path: "\($0)/EA Desktop/EADesktop.exe") }
            .filter { fileManager.fileExists(atPath: $0.path) }
            .max { $0.path.compare($1.path, options: .numeric) == .orderedAscending }
    }

    /// Chromium helpers that draw the client's window, relative to `drive_c`. Steam's moves between client
    /// versions (`bin/cef/cef.win7x64`, `cef.win64`), so a `*` stands for one folder name.
    var chromiumHelpers: [String] {
        switch self {
        case .steam: ["Program Files (x86)/Steam/bin/cef/*/steamwebhelper.exe"]
        case .epic, .gog, .eaApp, .ubisoft: []
        }
    }

    /// What opens the client's window.
    func clientArguments(clientReady: Bool) -> [String] {
        switch self {
        // Steam checks its files at every start and puts its own web helper back over `ChromiumHelper`'s, which
        // leaves its window black. Before its first update there is nothing to check.
        case .steam: ["-no-cef-sandbox"] + (clientReady ? ["-noverifyfiles"] : [])
        // The EA app's Chromium reads these from its own command line.
        case .eaApp: ["--disable-gpu", "--disable-gpu-compositing", "--in-process-gpu"]
        // The launcher draws its window with Unreal's OpenGL renderer: with its default Direct3D one the store
        // pages never appear over the Epic logo, since Chromium's GPU process can't start in Wine ("Failed to
        // launch GPU process" in cef3.log). No prerequisite installers at each start either.
        case .epic: ["-opengl", "-SkipBuildPatchPrereq"]
        case .gog, .ubisoft: []
        }
    }

    /// Whether games start through the client. GOG's games have no DRM and start by themselves.
    public var launchesGames: Bool { self != .gog }

    /// What asks the running client to start a game; it starts the client first if it isn't running.
    func playArguments(storeID: String) -> [String] {
        switch self {
        case .steam: ["-silent", "-applaunch", storeID]
        case .epic:
            ["com.epicgames.launcher://apps/\(storeID.replacingOccurrences(of: ":", with: "%3A"))"
                + "?action=launch&silent=true"]
        case .eaApp: ["link2ea://launchgame/\(storeID)?platform=PCWIN"]
        case .ubisoft: ["uplay://launch/\(storeID)/0"]
        case .gog: []
        }
    }

    /// What opens the client on removing one of its games. Steam has a link for it; the others open on their
    /// library, where the game is removed.
    func uninstallArguments(storeID: String) -> [String] {
        self == .steam ? ["steam://uninstall/\(storeID)"] : []
    }

    /// Games inherit the client's environment. Launchers that embed Qt WebEngine (CD Projekt's, Ubisoft's) are a
    /// Chromium too, and draw nothing with GPU compositing, like Steam's own window.
    var environment: [String: String] {
        ["QTWEBENGINE_CHROMIUM_FLAGS": "--disable-gpu --disable-gpu-compositing --in-process-gpu --no-sandbox",
         "QTWEBENGINE_DISABLE_SANDBOX": "1"]
    }
}
