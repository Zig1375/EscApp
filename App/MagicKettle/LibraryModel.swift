import AppKit
import Foundation
import MagicKettleKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The games Magic Kettle knows, and starting, watching and stopping them.
@MainActor @Observable
final class LibraryModel {
    enum PlayState: Equatable {
        case starting
        /// The game's window is up.
        case running(since: Date)
    }

    /// Something to tell the user, with the log when there is one.
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var message: String
        var log: URL?
    }

    private(set) var games: [GameRecord] = []
    private(set) var icons: [GameID: NSImage] = [:]
    private(set) var tints: [GameID: Color] = [:]
    /// Icons drawn edge to edge (opaque corners), shown filling their tile rather than inset in it.
    private(set) var fullBleedIcons: Set<GameID> = []
    /// Portrait covers: one the player chose (`CustomCovers`), else the store's (`StoreCovers`).
    /// A game installed from a disc usually has neither, only its icon, which the card shows instead.
    private(set) var covers: [GameID: NSImage] = [:]
    /// Games whose cover the player chose, which "Remove Cover" can take away.
    private(set) var customCovers: Set<GameID> = []
    private(set) var infos: [GameID: ExecutableInfo] = [:]
    /// Games whose program is no longer where the library says: the folder was moved or deleted (Daughter For
    /// Dessert's chapters 7–10, unpacked and later removed, kept their cards with a blank square and no reason).
    private(set) var missingFiles: Set<GameID> = []
    /// DirectX 12 games that can't start until D3DMetal is added (`LibraryModel+DirectX12`).
    var directX12Needs: [GameID: DirectX12Need] = [:]
    var states: [GameID: PlayState] = [:]
    var notice: Notice?
    /// The game that asked for DirectX 12, offered to start once the DirectX 12 window has added D3DMetal.
    var directX12Game: GameID?
    /// The game "Delete" asks about (`DeleteGameSheet`).
    var deleting: GameRecord?
    /// The game "Rename…" on its card asks a new name for.
    var renaming: GameRecord?
    /// The store game "Delete" asks to confirm: one click on it once removed a Steam game by accident.
    var confirmingDelete: GameRecord?
    var launch: Launch? {
        // While Magic Kettle looks for a first launch's settings, its screen covers the game's windows.
        didSet { tuningCover.update(showing: launch?.tuning != nil, library: self) }
    }
    let tuningCover = TuningCover()
    /// The install sheet, while a game is being installed from its installer or disc.
    var install: Install?
    /// An honest message about what won't run, or what a game needs (Problems.dc.html).
    var problem: Problem?
    /// "Diablo II started with WineD3D": shown after retries found a backend (Launching.dc.html, last panel).
    var learned: Learned?
    /// Ticks once a minute so "12 min" in the menu bar and cards stays current.
    private(set) var now = Date()
    /// Whether double-clicking an .exe in Finder opens Magic Kettle.
    private(set) var isDefaultForExe = true
    /// Settings → General: the Retina setting new games get (`SharedSettings`).
    private(set) var newGameRetina = GameScaling.Setting.auto
    /// Stores whose client is installed (Stores.dc.html).
    var installedStores: Set<Store> = []
    /// Stores being installed, with how far each is.
    var storeInstalls: [Store: StoreClient.Step] = [:]
    var storeTasks: [Store: Task<Void, Never>] = [:]
    /// Stores whose client runs, looked at every few seconds (`StoreKeeper`).
    var runningStores: Set<Store> = []
    /// Stores the app is closing and opening again (deleting one of their games).
    var restartingStores: Set<Store> = []
    /// Stores whose client "Stop" is closing; Steam may take up to 20 s to save and quit.
    var stoppingStores: Set<Store> = []
    /// Stores opened from the store row whose client isn't up yet: Steam takes a while to show its window, and
    /// without a sign the player clicked again.
    var openingStores: Set<Store> = []
    /// Stores being removed with their games.
    var removingStores: Set<Store> = []
    /// The screenshot shown over the whole window (`ScreenshotViewer`).
    var viewing: Viewing?

    struct Viewing: Equatable {
        var shots: [StoreScreenshots.Shot]
        var source: StoreScreenshots.Source
        var index: Int
    }
    /// Set to show a screen in the main window: Stores from a "needs Steam" message, a game's Advanced
    /// settings from the first-launch check.
    var shownPage: LibraryView.Page?

    let paths: AppPaths
    var sessions: [GameID: GameSession] = [:]
    var launchTasks: [GameID: Task<Void, Never>] = [:]
    /// The checking of the launch that's showing; "Don't Retry" stops it.
    var launchControl: LaunchControl?
    /// Files opened before the components were installed, or discs and installers opened while they update;
    /// opened once that finishes.
    var pending: [URL] = []
    private(set) var isReady = false
    /// Components are downloading or installing (`ComponentsModel.updating`). A game started meanwhile did
    /// nothing: the player could press Play and wait for a game that never came. Until it ends, Play is off.
    var isUpdatingComponents = false {
        didSet { if oldValue, !isUpdatingComponents { updateFinished() } }
    }
    /// Games opened (a double-click on their exe) while components update: they are in the library already and
    /// start by themselves once the update finishes.
    var startsAfterUpdate: [GameID] = []
    /// Keeps the next game's Wine running so it starts at once (`BottleWarmer`).
    let warmer: BottleWarmer
    /// Cools the warm bottles a few seconds after Magic Kettle loses focus.
    var coolTask: Task<Void, Never>?
    /// Warms a hovered card once the pointer has rested on it.
    var hoverTask: Task<Void, Never>?

    init(paths: AppPaths = .standard()) {
        self.paths = paths
        warmer = BottleWarmer(paths: paths)
    }

    func reload() {
        let loaded = try? GameLibrary.load(from: paths.library)
        games = (loaded?.games ?? [])
            .sorted { ($0.lastPlayed ?? $0.addedAt) > ($1.lastPlayed ?? $1.addedAt) }
        // Only from a library that was read: an unreadable Games.json must not take every cover with it.
        if let loaded { CustomCovers.prune(keeping: Set(loaded.games.map(\.id)), paths: paths) }
        refreshMissingFiles()
        for game in games where icons[game.id] == nil { loadIcon(for: game) }
        // Asked again on each reload: Steam downloads a new game's cover some time after the game appears.
        for game in games where covers[game.id] == nil { loadCover(for: game) }
        refreshDirectX12Needs()
        refreshDefaultHandler()
        newGameRetina = SharedSettings.load(from: paths.settings).newGameRetina ?? .auto
    }

    /// Games already in the library keep their own setting.
    func setNewGameRetina(_ setting: GameScaling.Setting) {
        var settings = SharedSettings.load(from: paths.settings)
        settings.newGameRetina = setting == .auto ? nil : setting
        do {
            try settings.save(to: paths.settings)
            newGameRetina = setting
        } catch {
            notice = Notice(title: String(localized: "Couldn't save the setting"), message: error.localizedDescription)
        }
    }

    /// Setup finished: play whatever the user opened while it ran.
    func becameReady() {
        guard !isReady else { return }
        isReady = true
        startClock()
        reload()
        watchFocus()
        watchStores()
        // Discs left attached when Magic Kettle last quit or crashed.
        Task { [paths] in await DiscImage.detachAll(paths: paths) }
        let waiting = pending
        pending = []
        for url in waiting { open(url) }
    }

    /// A file from Finder, the Dock icon or the window.
    func open(_ url: URL) {
        guard isReady else {
            pending.append(url)
            return
        }
        if waitsForUpdate(url) { return }
        if DiscImage.isImage(url) { return openDisc(url) }
        if let kind = InstallerKind.detect(url) { return openInstaller(url, kind: kind) }
        if let kind = Self.problem(with: url) { return problem = Problem(kind: kind) }
        do {
            let game = try GameIdentifier(paths: paths).identify(executable: url).record
            reload()
            checkDirectX12Need(of: game)
            play(game)
        } catch {
            notice = Notice(title: String(localized: "Magic Kettle can't open this file"),
                            message: String(describing: error))
        }
    }

    func stop(_ game: GameRecord) {
        guard let session = sessions[game.id] else { return }
        Task { await session.stop() }
    }

    /// "Show Game": brings the running game's window to the front.
    func showGame(_ game: GameRecord) {
        guard let session = sessions[game.id] else { return }
        let owners = GameWindows.owners(of: session)
        GameWindows.bringForward(owners.first ?? session.processID)
    }

    /// Games whose window is up, with when they started, for the cards and the menu bar.
    var runningGames: [(game: GameRecord, since: Date)] {
        games.compactMap { game in
            if case let .running(since)? = states[game.id] { (game, since) } else { nil }
        }
    }

    /// A game starting or running, or one being installed: Magic Kettle mustn't quit when its window closes.
    var isBusy: Bool {
        !states.isEmpty || install != nil
    }

    /// Keeps `now` current for durations shown while games run.
    func startClock() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Date()
            }
        }
    }

    func removeFromApp(_ game: GameRecord) {
        Task {
            // Its bottle is about to be deleted; Wine mustn't be running in it.
            await warmer.cool(game.id)
            do {
                try GameRemover.removeFromApp(game.id, paths: paths)
                icons[game.id] = nil
                reload()
            } catch {
                notice = Notice(title: String(localized: "Couldn't remove \(game.name)"),
                                message: String(describing: error))
            }
        }
    }

    func game(_ id: GameID) -> GameRecord? { games.first { $0.id == id } }

    /// Lets the user pick which exe in the game's folder starts the game (a launcher instead of the game).
    func chooseExecutable(for game: GameRecord) {
        guard !isPlaying(game.id) else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: game.folder, directoryHint: .isDirectory)
        panel.allowedContentTypes = [UTType("com.microsoft.windows-executable")].compactMap { $0 }
        panel.message = String(localized: "Choose which program starts \(game.name)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await warmer.cool(game.id) }
        update(game.id) { $0.executable = url.path(percentEncoded: false) }
        icons[game.id] = nil
        reload()
    }

    func makeDefaultForExe() {
        Task {
            let types = [UTType("com.microsoft.windows-executable"), UTType(filenameExtension: "msi")]
                .compactMap { $0 }
            // Launch Services picks among copies with this bundle id, and kept picking a day-old development
            // build in DerivedData: double-clicking an .exe opened that copy, with its old first-launch screen.
            // Registering this copy first makes it the one chosen.
            LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
            for type in types {
                try? await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
            }
            // Launch Services takes a moment to answer with the new handler after the player approves.
            for _ in 0..<10 where !isDefaultForExe {
                refreshDefaultHandler()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// By bundle id, not path: with two copies of Magic Kettle on the Mac (a development build in DerivedData and one
    /// elsewhere) Launch Services may name the other copy, and the switch in Settings stayed off after it was
    /// approved. `makeDefaultForExe` registers this copy first so that it is the one that opens.
    func refreshDefaultHandler() {
        guard let type = UTType("com.microsoft.windows-executable"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: type) else {
            isDefaultForExe = false
            return
        }
        isDefaultForExe = Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    func currentRuntime() throws -> (RuntimeManifest.Runtime, [KnownGame])? {
        let manifest = try ManifestUpdater(paths: paths).current()
        let installed = RuntimeInstaller(paths: paths).installedRuntimes()
        let runtime = RuntimeCatalog(installed: installed, manifest: manifest, app: .thisApp, macOS: .thisMac).current
        return runtime.map { ($0, manifest.games ?? []) }
    }

    private func loadCover(for game: GameRecord) {
        let paths = paths
        Task.detached(priority: .utility) {
            let custom = CustomCovers.cover(for: game.id, paths: paths)
            var file = custom
            if file == nil { file = await StoreCovers.cover(for: game, paths: paths) }
            guard let file, let image = NSImage(contentsOf: file) else { return }
            await MainActor.run {
                self.covers[game.id] = image
                if custom != nil { self.customCovers.insert(game.id) }
            }
        }
    }

    /// "Choose Cover…": a picture from the Mac becomes the game's cover, on its card and its page.
    func chooseCover(for game: GameRecord) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        let name = game.name
        panel.message = String(localized: "Choose a picture for \(name). An upright one, like 600 × 900, fits best.")
        panel.prompt = String(localized: "Use as Cover")
        guard panel.runModal() == .OK, let picture = panel.url else { return }
        do {
            let file = try CustomCovers.set(picture, for: game.id, paths: paths)
            covers[game.id] = NSImage(contentsOf: file)
            customCovers.insert(game.id)
        } catch {
            notice = Notice(title: String(localized: "Couldn't use this picture"),
                            message: String(localized: "Choose a picture file, such as PNG, JPEG or HEIC."))
        }
    }

    /// "Remove Cover": back to the store's cover, or the icon.
    func removeCover(for game: GameRecord) {
        CustomCovers.remove(for: game.id, paths: paths)
        covers[game.id] = nil
        customCovers.remove(game.id)
        loadCover(for: game)
    }

    fileprivate func loadIcon(for game: GameRecord) {
        let exe = URL(filePath: game.executable)
        Task.detached(priority: .utility) {
            guard let info = try? ExecutableInfo.read(exe) else { return }
            let image = info.icon.flatMap(NSImage.init(data:))
            let tint = image?.averageColor.map { Color(nsColor: $0) }
            let fullBleed = image?.hasOpaqueCorners == true
            await MainActor.run {
                self.infos[game.id] = info
                self.icons[game.id] = image
                self.tints[game.id] = tint
                if fullBleed { self.fullBleedIcons.insert(game.id) } else { self.fullBleedIcons.remove(game.id) }
            }
        }
    }
}

extension LibraryModel {
    /// Checked on every reload and whenever Magic Kettle comes to the front, since the folder is usually put back or
    /// removed in Finder. A game whose program is back gets its icon read again.
    func refreshMissingFiles() {
        let missing = Set(games.filter { !FileManager.default.fileExists(atPath: $0.executable) }.map(\.id))
        guard missing != missingFiles else { return }
        for game in games where missingFiles.contains(game.id) && !missing.contains(game.id) { loadIcon(for: game) }
        missingFiles = missing
    }
}

extension NSImage {
    /// A square picture with no transparent margin (GameMaker's default icon, for one): inset in its tile it
    /// looks cut off at the edges.
    var hasOpaqueCorners: Bool {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        let corners = [0, side - 1, side * (side - 1), side * side - 1]
        return corners.allSatisfy { pixels[$0 * 4 + 3] > 240 }
    }

    /// The icon's overall colour, for the tinted square behind it.
    var averageColor: NSColor? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let alpha = CGFloat(pixel[3]) / 255
        guard alpha > 0.05 else { return nil }
        return NSColor(srgbRed: CGFloat(pixel[0]) / 255 / alpha, green: CGFloat(pixel[1]) / 255 / alpha,
                       blue: CGFloat(pixel[2]) / 255 / alpha, alpha: 1)
    }
}
