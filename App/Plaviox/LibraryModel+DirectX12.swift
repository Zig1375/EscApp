import AppKit
import Foundation
import PlavioxKit

/// DirectX 12 games while D3DMetal isn't added (`DirectX12Need`). Players learned it only from a launch that
/// failed; now the card and the game's page say so, and Play opens the explanation instead of starting a launch.
extension LibraryModel {
    /// Reads every game's need again: after the library changes, and after D3DMetal is added or removed.
    func refreshDirectX12Needs() {
        let games = games
        let paths = paths
        Task.detached(priority: .utility) {
            let needs = Self.directX12Needs(of: games, paths: paths)
            await MainActor.run { self.directX12Needs = needs }
        }
    }

    /// Just added, the needs go at once, so "Start <game>" at the end of the DirectX 12 window starts the game
    /// rather than this explanation again; the check that follows brings back any the components can't run yet.
    func d3dmetalChanged(added: Bool) {
        if added { directX12Needs = [:] }
        refreshDirectX12Needs()
    }

    /// The same for one game, at once: a game just opened from Finder starts right after.
    func checkDirectX12Need(of game: GameRecord) {
        directX12Needs[game.id] = Self.directX12Needs(of: [game], paths: paths)[game.id]
    }

    /// Play on a game that needs DirectX 12: the explanation instead of a launch. True when it was shown.
    func askedForDirectX12(_ game: GameRecord) -> Bool {
        guard let need = directX12Needs[game.id] else { return false }
        askForDirectX12(game, need)
        return true
    }

    /// The explanation, with the DirectX 12 window one click away; the game is offered to start when it's done.
    func askForDirectX12(_ game: GameRecord, _ need: DirectX12Need) {
        launch = nil
        directX12Game = game.id
        problem = Problem(kind: .needsDirectX12(need))
        NSApp.activate()
    }

    nonisolated private static func directX12Needs(of games: [GameRecord],
                                                   paths: AppPaths) -> [GameID: DirectX12Need] {
        guard let manifest = try? ManifestUpdater(paths: paths).current(),
              let runtime = RuntimeCatalog(installed: RuntimeInstaller(paths: paths).installedRuntimes(),
                                           manifest: manifest, app: .thisApp, macOS: .thisMac).current
        else { return [:] }
        let modules = GameModulesUpdater(paths: paths).current().modules
        var needs: [GameID: DirectX12Need] = [:]
        for game in games {
            needs[game.id] = DirectX12Need.check(game, runtime: runtime, modules: modules, paths: paths)
        }
        return needs
    }
}
