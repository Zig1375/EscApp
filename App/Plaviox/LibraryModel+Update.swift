import Foundation
import PlavioxKit

/// While components download or install, nothing starts: a game started meanwhile did nothing, and the player
/// pressed Play again and again. Play is off, and what is opened meanwhile waits and then starts by itself.
extension LibraryModel {
    /// Whether Play does anything now: not while the game already starts or runs, nor while components update.
    func canPlay(_ game: GameRecord) -> Bool {
        states[game.id] == nil && !isUpdatingComponents
    }

    /// Components are updating, so the game can't start yet. The buttons are off meanwhile; the ways in that
    /// have none (a double-click on the exe, an installer's last step) queue the game and say so, or the player
    /// would wait for a game that never came.
    func waitsForUpdate(_ game: GameRecord) -> Bool {
        guard isUpdatingComponents else { return false }
        if !startsAfterUpdate.contains(game.id) { startsAfterUpdate.append(game.id) }
        notice = Notice(title: String(localized: "\(game.name) will start after the update"),
                        message: String(localized: """
                            The game is in your library. Plaviox is installing what games need to run and will start \
                            it by itself when that's done.
                            """))
        return true
    }

    /// A disc or an installer opened during the update waits for it. A game's exe goes on to `play`, which adds
    /// it to the library and has it wait.
    func waitsForUpdate(_ url: URL) -> Bool {
        guard isUpdatingComponents, DiscImage.isImage(url) || InstallerKind.detect(url) != nil else { return false }
        pending.append(url)
        notice = Notice(title: String(localized: "Plaviox will open this once the update finishes"),
                        message: String(localized: """
                            Plaviox is installing what games need to run. \(url.lastPathComponent) opens by itself \
                            when that's done.
                            """))
        return true
    }

    /// The update ended (installed or failed; either way a runtime is there to play with): open and start what
    /// waited for it.
    func updateFinished() {
        let waiting = pending
        pending = []
        for url in waiting { open(url) }
        let games = startsAfterUpdate.compactMap(game)
        startsAfterUpdate = []
        for game in games { play(game) }
    }
}
