import Foundation

extension GameLauncher {
    /// The backend this launch uses; throws when the game can't run at all.
    func backend(for game: GameRecord, info: ExecutableInfo, runtime: RuntimeManifest.Runtime,
                 override: GraphicsBackend?) throws -> GraphicsBackend {
        let d3dmetal = D3DMetal.isReady(paths: paths, runtime: runtime)
        switch BackendPlan.forTraits(info.traits, d3dmetal: d3dmetal) {
        case let .attempts(attempts):
            let backend = override ?? game.backend ?? attempts[0]
            // D3DMetal chosen for this game (by hand, or recommended by its folder from another Mac) but not here,
            // or removed since: the game's own first choice instead.
            return backend == .d3dmetal && !d3dmetal ? attempts[0] : backend
        case let .unsupported(reason):
            throw LaunchError.unsupported(reason)
        }
    }
}
