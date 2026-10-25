import AppKit
import EscAppKit
import Foundation

/// The game page's actions: details, files, logs, settings that change a game's record.
extension LibraryModel {
    /// Applied to the bottle at the next launch (the registry can't change while the game runs).
    func setWindowsVersion(_ version: WindowsVersion, for game: GameRecord) {
        // A warm bottle's registry can't change under its running Wine.
        Task { await warmer.cool(game.id) }
        update(game.id) { $0.windowsVersion = version }
    }

    func runs(for game: GameRecord) -> [LaunchHistory.Run] {
        LaunchHistory.runs(in: paths.logs(forGame: game.id))
    }

    /// Size of the game's folder on disk.
    func folderSize(of game: GameRecord) async -> Int64 {
        let folder = URL(filePath: game.folder, directoryHint: .isDirectory)
        return await Task.detached(priority: .utility) { LibraryModel.allocatedSize(of: folder) }.value
    }

    nonisolated static func allocatedSize(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// "From disk": the game's folder goes to the Trash (recoverable), then EscApp forgets the game.
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

    /// The player's own name, on the card and the page. Only for their own games (`GameRecord.canRename`).
    func rename(_ game: GameRecord, to name: String) {
        update(game.id) { $0.rename(to: name) }
    }

    func update(_ id: GameID, _ change: (inout GameRecord) -> Void) {
        do {
            try GameLibrary.modify(paths.library) { library in
                guard var game = library[id] else { return }
                change(&game)
                library[id] = game
            }
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
}
