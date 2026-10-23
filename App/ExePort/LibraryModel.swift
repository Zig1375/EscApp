import AppKit
import ExePortKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The games ExePort knows, and starting, watching and stopping them.
@MainActor @Observable
final class LibraryModel {
    enum PlayState: Equatable {
        case starting
        /// The game's window is up.
        case running(since: Date)
    }

    /// The "getting the game ready" sheet (Launching.dc.html, first panel).
    struct Launch: Identifiable, Equatable {
        enum StepState: Equatable { case waiting, active, done }

        let id: GameID
        let name: String
        let firstTime: Bool
        var windows: (version: WindowsVersion, firstTime: Bool)?
        var windowsState: StepState = .active
        var graphics: String?
        var startState: StepState = .waiting
        /// Set after a while without a game window, to say that this can take a minute.
        var slow = false

        static func == (lhs: Launch, rhs: Launch) -> Bool {
            lhs.id == rhs.id && lhs.windows?.version == rhs.windows?.version
                && lhs.windows?.firstTime == rhs.windows?.firstTime && lhs.windowsState == rhs.windowsState
                && lhs.graphics == rhs.graphics && lhs.startState == rhs.startState && lhs.slow == rhs.slow
        }
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
    private(set) var infos: [GameID: ExecutableInfo] = [:]
    private(set) var states: [GameID: PlayState] = [:]
    var notice: Notice?
    var launch: Launch?
    /// Ticks once a minute so "12 min" in the menu bar and cards stays current.
    private(set) var now = Date()
    /// Whether double-clicking an .exe in Finder opens ExePort.
    private(set) var isDefaultForExe = true

    let paths: AppPaths
    private var sessions: [GameID: GameSession] = [:]
    private var launchTasks: [GameID: Task<Void, Never>] = [:]
    /// Files opened before the components were installed; played once setup finishes.
    private var pending: [URL] = []
    private var isReady = false

    init(paths: AppPaths = .standard()) {
        self.paths = paths
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
        if url.pathExtension.lowercased() == "msi" {
            notice = Notice(title: String(localized: "Installers are coming soon"),
                            message: String(localized: """
                                ExePort can't run .msi installers yet. Installing games arrives in a later version.
                                """))
            return
        }
        do {
            let game = try GameIdentifier(paths: paths).identify(executable: url).record
            reload()
            play(game)
        } catch {
            notice = Notice(title: String(localized: "ExePort can't open this file"),
                            message: String(describing: error))
        }
    }

    func play(_ game: GameRecord) {
        guard states[game.id] == nil else { return }
        states[game.id] = .starting
        launch = Launch(id: game.id, name: game.name, firstTime: (game.launches ?? 0) == 0)
        let paths = paths
        launchTasks[game.id] = Task {
            defer {
                states[game.id] = nil
                sessions[game.id] = nil
                launchTasks[game.id] = nil
                if launch?.id == game.id { launch = nil }
                reload()
            }
            do {
                guard let runtime = try currentRuntime() else {
                    notice = Notice(title: String(localized: "Components aren't installed"),
                                    message: String(localized: "Open Settings → Components to install them."))
                    return
                }
                let launcher = GameLauncher(paths: paths)
                let prepared = try await launcher.prepare(game, runtime: runtime) { step in
                    Task { @MainActor in self.apply(step, to: game.id) }
                }
                try Task.checkCancellation()
                let outcome = try await launcher.run(prepared) { session in
                    Task { @MainActor in
                        self.sessions[game.id] = session
                        self.watchForWindow(of: game.id, session: session)
                    }
                }
                var library = try GameLibrary.load(from: paths.library)
                library.recordPlay(of: game.id, outcome: outcome)
                try library.save(to: paths.library)
                if !outcome.worked {
                    notice = Notice(
                        title: String(localized: "\(game.name) closed right after starting"),
                        message: String(localized: """
                            ExePort will learn to try other settings by itself soon. \
                            For now the log may show what went wrong.
                            """),
                        log: outcome.log)
                }
            } catch is CancellationError {
                // The player pressed Cancel.
            } catch {
                notice = Notice(title: String(localized: "\(game.name) can't start"),
                                message: String(describing: error))
            }
        }
    }

    /// "Cancel" in the launch sheet: stop whatever has started and forget the launch.
    func cancelLaunch() {
        guard let id = launch?.id else { return }
        launch = nil
        launchTasks[id]?.cancel()
        if let session = sessions[id] { Task { await session.stop() } }
    }

    func stop(_ game: GameRecord) {
        guard let session = sessions[game.id] else { return }
        Task { await session.stop() }
    }

    /// "Show Game": brings the running game's window to the front.
    func showGame(_ game: GameRecord) {
        guard let session = sessions[game.id] else { return }
        let owners = GameWindows.owners(under: session.wineRoot)
        GameWindows.bringForward(owners.first ?? session.processID)
    }

    /// Games whose window is up, with when they started, for the cards and the menu bar.
    var runningGames: [(game: GameRecord, since: Date)] {
        games.compactMap { game in
            if case let .running(since)? = states[game.id] { (game, since) } else { nil }
        }
    }

    private func apply(_ step: GameLauncher.Step, to id: GameID) {
        guard var current = launch, current.id == id else { return }
        switch step {
        case let .windows(version, firstTime):
            current.windows = (version, firstTime)
            current.windowsState = .active
        case let .graphics(backend, directX):
            current.windowsState = .done
            let api: String? = switch directX {
            case .legacy?: "DirectDraw"
            case .d3d9?: "DirectX 9"
            case .d3d11?: "DirectX 11"
            case .d3d12?: "DirectX 12"
            case nil: nil
            }
            current.graphics = api.map { "\(backend.displayName) (\($0))" } ?? backend.displayName
        case .starting:
            current.startState = .active
        }
        launch = current
    }

    /// Waits for the game's first window, then brings it forward and marks the game as running. Says so when
    /// it takes long: Wine's first start under Rosetta can need most of a minute.
    private func watchForWindow(of id: GameID, session: GameSession) {
        Task {
            let started = Date()
            while sessions[id] != nil, states[id] == .starting {
                if let owner = GameWindows.owners(under: session.wineRoot).first {
                    states[id] = .running(since: Date())
                    if launch?.id == id { launch = nil }
                    GameWindows.bringForward(owner)
                    return
                }
                if Date().timeIntervalSince(started) > 15, launch?.id == id, launch?.slow == false {
                    launch?.slow = true
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
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
        do {
            try GameRemover.removeFromApp(game.id, paths: paths)
            icons[game.id] = nil
            reload()
        } catch {
            notice = Notice(title: String(localized: "Couldn't remove \(game.name)"),
                            message: String(describing: error))
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
        update(game.id) { $0.executable = url.path(percentEncoded: false) }
        icons[game.id] = nil
        reload()
    }

    func makeDefaultForExe() {
        Task {
            let types = [UTType("com.microsoft.windows-executable"), UTType(filenameExtension: "msi")].compactMap { $0 }
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

    private func currentRuntime() throws -> RuntimeManifest.Runtime? {
        let manifest = try ManifestUpdater(paths: paths).current()
        let installed = RuntimeInstaller(paths: paths).installedRuntimes()
        return RuntimeCatalog(installed: installed, manifest: manifest, app: .thisApp, macOS: .thisMac).current
    }

    private func loadIcon(for game: GameRecord) {
        let exe = URL(filePath: game.executable)
        Task.detached(priority: .utility) {
            guard let info = try? ExecutableInfo.read(exe) else { return }
            let image = info.icon.flatMap(NSImage.init(data:))
            let tint = image?.averageColor.map { Color(nsColor: $0) }
            await MainActor.run {
                self.infos[game.id] = info
                self.icons[game.id] = image
                self.tints[game.id] = tint
            }
        }
    }
}

extension NSImage {
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
