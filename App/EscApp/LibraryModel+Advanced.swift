import AppKit
import EscAppKit
import Foundation

/// The Advanced screen's actions (Advanced.dc.html).
extension LibraryModel {
    /// Changes a setting that applies at the next launch. The game's warm bottle is cooled first: settings go into
    /// its registry, which can't change under a running Wine.
    func changeSetting(of id: GameID, _ change: @escaping (inout GameRecord) -> Void) {
        Task { await warmer.cool(id) }
        update(id, change)
    }

    /// What the game's Windows takes on disk, and what Finder shows for it.
    func bottleSize(of id: GameID) async -> (unique: Int64, apparent: Int64)? {
        let paths = paths
        return await Task.detached(priority: .utility) { DiskUsage.bottle(of: id, paths: paths) }.value
    }

    /// "Copy Report" from the game's last log.
    func copyLastReport(for game: GameRecord) {
        guard let log = latestLog(for: game) else { return }
        let runtime = (try? currentRuntime())??.0.id ?? "-"
        let report = LaunchReport.text(game: game, log: log, runtime: runtime, macOS: Version.thisMac.description,
                                       app: Version.thisApp.description)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    /// "Reset Windows…": the next launch makes the game a clean bottle.
    func resetWindows(of game: GameRecord) {
        Task {
            await warmer.cool(game.id)
            do {
                try BottleManager(paths: paths).reset(game.id)
            } catch {
                notice = Notice(title: String(localized: "Couldn't reset the Windows of \(game.name)"),
                                message: String(describing: error))
            }
        }
    }
}
