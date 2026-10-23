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
        case running
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
    /// Whether double-clicking an .exe in Finder opens ExePort.
    private(set) var isDefaultForExe = true

    private let paths: AppPaths
    private var sessions: [GameID: GameSession] = [:]
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
        isReady = true
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
        let paths = paths
        Task {
            defer {
                states[game.id] = nil
                sessions[game.id] = nil
                reload()
            }
            do {
                guard let runtime = try currentRuntime() else {
                    notice = Notice(title: String(localized: "Components aren't installed"),
                                    message: String(localized: "Open Settings → Components to install them."))
                    return
                }
                let launcher = GameLauncher(paths: paths)
                let prepared = try await launcher.prepare(game, runtime: runtime)
                states[game.id] = .running
                let outcome = try await launcher.run(prepared) { session in
                    Task { @MainActor in self.sessions[game.id] = session }
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
            } catch {
                notice = Notice(title: String(localized: "\(game.name) can't start"),
                                message: String(describing: error))
            }
        }
    }

    func stop(_ game: GameRecord) {
        guard let session = sessions[game.id] else { return }
        Task { await session.stop() }
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

    /// Applied to the bottle at the next launch (the registry can't change while the game runs).
    func setWindowsVersion(_ version: WindowsVersion, for game: GameRecord) {
        update(game.id) { $0.windowsVersion = version }
    }

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

    func runs(for game: GameRecord) -> [LaunchHistory.Run] {
        LaunchHistory.runs(in: paths.logs(forGame: game.id))
    }

    /// Size of the game's folder on disk.
    func folderSize(of game: GameRecord) async -> Int64 {
        let folder = URL(filePath: game.folder, directoryHint: .isDirectory)
        return await Task.detached(priority: .utility) { Self.allocatedSize(of: folder) }.value
    }

    nonisolated private static func allocatedSize(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// "From disk": the game's folder goes to the Trash (recoverable), then ExePort forgets the game.
    func moveToTrash(_ game: GameRecord) {
        let folder = URL(filePath: game.folder, directoryHint: .isDirectory)
        NSWorkspace.shared.recycle([folder]) { _, error in
            Task { @MainActor in
                if let error {
                    self.notice = Notice(title: String(localized: "Couldn't move \(game.name) to the Trash"),
                                         message: error.localizedDescription)
                } else {
                    self.removeFromApp(game)
                }
            }
        }
    }

    private func update(_ id: GameID, _ change: (inout GameRecord) -> Void) {
        do {
            var library = try GameLibrary.load(from: paths.library)
            guard var game = library[id] else { return }
            change(&game)
            library[id] = game
            try library.save(to: paths.library)
            reload()
        } catch {
            notice = Notice(title: String(localized: "Couldn't save the change"), message: String(describing: error))
        }
    }

    func showInFinder(_ game: GameRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: game.executable)])
    }

    func latestLog(for game: GameRecord) -> URL? {
        let folder = paths.logs(forGame: game.id)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".log") }.max().map { folder.appending(path: $0) }
    }

    func openLog(_ url: URL) {
        NSWorkspace.shared.open(url)
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
