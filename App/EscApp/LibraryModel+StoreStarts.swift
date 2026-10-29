import AppKit
import EscAppKit
import Foundation

/// Store games started from the store's own window (`StoreGameStarts`): they show as playing like any other, and
/// one that needs EscApp's launch gets it, launch sheet included.
extension LibraryModel {
    /// Looks every 2 seconds while a store's client runs.
    func watchStoreStarts() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard isReady, !isUpdatingComponents, !runningStores.isEmpty else { continue }
                await takeOverStoreStarts()
            }
        }
    }

    private func takeOverStoreStarts() async {
        let candidates = games.filter { $0.store.map(runningStores.contains) ?? false }
        guard !candidates.isEmpty else { return }
        let skipping = Set(states.keys).union(launch.map { [$0.id] } ?? [])
        let runtime = (try? currentRuntime())?.0
        let paths = paths
        let found = await Task.detached(priority: .utility) {
            StoreGameStarts.find(in: candidates, skipping: skipping, paths: paths, runtime: runtime)
        }.value
        for item in found where states[item.game.id] == nil && launch?.id != item.game.id {
            switch item.verdict {
            case .adopt: adopt(item)
            case .prepare: await startAgain(item)
            }
        }
    }

    /// Shows the game as playing until its processes are gone, and counts its time. One that freezes on a blank
    /// window with graphics EscApp found (not the player's choice) is closed, and its settings are looked for
    /// again with the first-launch screen.
    private func adopt(_ found: StoreGameStarts.Found) {
        let id = found.game.id
        states[id] = .running(since: found.since)
        sessions[id] = found.session
        let paths = paths
        Task {
            async let ended: Void = StoreGameStarts.follow(found, paths: paths)
            let frozen = found.game.chosenBackend == nil ? await StoreGameStarts.freezes(found) : false
            if frozen { await found.session.stop() }
            await ended
            if case .running? = states[id] { states[id] = nil }
            sessions[id] = nil
            reload()
            guard frozen else { return }
            update(id) { $0.forgetLaunchSettings() }
            if let game = game(id) {
                play(game)
                NSApp.activate()
            }
        }
    }

    /// Closes the game the client just started and starts it the way EscApp does, with the launch sheet in
    /// front of the client's window.
    private func startAgain(_ found: StoreGameStarts.Found) async {
        let id = found.game.id
        states[id] = .starting
        await found.session.stop()
        states[id] = nil
        guard let game = game(id) else { return }
        play(game)
        NSApp.activate()
    }
}
