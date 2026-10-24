import AppKit
import EscAppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The games EscApp knows, and starting, watching and stopping them.
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
    private(set) var infos: [GameID: ExecutableInfo] = [:]
    var states: [GameID: PlayState] = [:]
    var notice: Notice?
    var launch: Launch? {
        // While EscApp looks for a first launch's settings, its screen covers the game's windows.
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
    /// Whether double-clicking an .exe in Finder opens EscApp.
    private(set) var isDefaultForExe = true
    /// Stores whose client is installed (Stores.dc.html).
    var installedStores: Set<Store> = []
    /// Stores being installed, with how far each is.
    var storeInstalls: [Store: StoreClient.Step] = [:]
    var storeTasks: [Store: Task<Void, Never>] = [:]
    /// Set to show a screen in the main window: Stores from Settings or a "needs Steam" message, a game's Advanced
    /// settings from the first-launch check.
    var shownPage: LibraryView.Page?

    let paths: AppPaths
    var sessions: [GameID: GameSession] = [:]
    var launchTasks: [GameID: Task<Void, Never>] = [:]
    /// The checking of the launch that's showing; "Don't Retry" stops it.
    var launchControl: LaunchControl?
    /// Files opened before the components were installed; played once setup finishes.
    private var pending: [URL] = []
    private(set) var isReady = false
    /// Keeps the next game's Wine running so it starts at once (`BottleWarmer`).
    let warmer: BottleWarmer
    /// Cools the warm bottles a few seconds after EscApp loses focus.
    var coolTask: Task<Void, Never>?
    /// Warms a hovered card once the pointer has rested on it.
    var hoverTask: Task<Void, Never>?

    init(paths: AppPaths = .standard()) {
        self.paths = paths
        warmer = BottleWarmer(paths: paths)
    }

    func reload() {
        games = ((try? GameLibrary.load(from: paths.library))?.games ?? [])
            .sorted { ($0.lastPlayed ?? $0.addedAt) > ($1.lastPlayed ?? $1.addedAt) }
        for game in games where icons[game.id] == nil { loadIcon(for: game) }
        refreshDefaultHandler()
    }

    /// Setup finished: play whatever the user opened while it ran.
    func becameReady() {
        guard !isReady else { return }
        isReady = true
        startClock()
        reload()
        watchFocus()
        watchStores()
        // Discs left attached when EscApp last quit or crashed.
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
        if DiscImage.isImage(url) { return openDisc(url) }
        if let kind = InstallerKind.detect(url) { return openInstaller(url, kind: kind) }
        if let kind = Self.problem(with: url) { return problem = Problem(kind: kind) }
        do {
            let game = try GameIdentifier(paths: paths).identify(executable: url).record
            reload()
            play(game)
        } catch {
            notice = Notice(title: String(localized: "EscApp can't open this file"),
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
            for type in types {
                try? await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
            }
            refreshDefaultHandler()
        }
    }

    private func refreshDefaultHandler() {
        guard let type = UTType("com.microsoft.windows-executable"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: type) else {
            isDefaultForExe = false
            return
        }
        isDefaultForExe = handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    func currentRuntime() throws -> (RuntimeManifest.Runtime, [KnownGame])? {
        let manifest = try ManifestUpdater(paths: paths).current()
        let installed = RuntimeInstaller(paths: paths).installedRuntimes()
        let runtime = RuntimeCatalog(installed: installed, manifest: manifest, app: .thisApp, macOS: .thisMac).current
        return runtime.map { ($0, manifest.games ?? []) }
    }

    private func loadIcon(for game: GameRecord) {
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
