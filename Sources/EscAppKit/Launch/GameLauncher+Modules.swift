import Foundation

extension GameLauncher {
    /// The launch log names the game's module and its revision, or why it wasn't applied: a module that should
    /// have changed a launch and didn't is found from the log alone.
    func moduleNotes(_ game: GameRecord, _ info: ExecutableInfo, _ runtime: RuntimeManifest.Runtime) -> [String] {
        let modules = GameModulesUpdater(paths: paths).current().modules
        guard let (module, launch) = GameModules.resolve(game, info: info, runtime: runtime, modules: modules,
                                                         app: GameModules.appVersion) else { return [] }
        switch launch {
        case .success:
            return ["[EscApp] Game settings \(module.id) revision \(module.revision)"]
        case let .failure(.wine(installed)):
            return ["[EscApp] Game settings \(module.id) revision \(module.revision) not applied: Wine \(installed)"]
        }
    }
}
