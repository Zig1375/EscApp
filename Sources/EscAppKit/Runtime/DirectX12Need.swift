import Foundation

/// Why a game can't start without D3DMetal. Players learned it only from a failed launch; with this the library
/// says so on the game's card and page, and the first click leads to the DirectX 12 setup instead of a launch.
public enum DirectX12Need: Sendable, Equatable {
    /// The game's exe imports `d3d12.dll`: nothing else runs DirectX 12 (`BackendPlan`).
    case directX12
    /// The game's module requires D3DMetal: the exe gave no sign (a launcher, or DirectX 12 loaded at run time),
    /// and without it the game would start on DXVK and fail.
    case gameSettings

    /// The need, from what the exe imports and what the game's module asks for; nil when the game runs without
    /// D3DMetal.
    public static func of(traits: ExecutableTraits?, module: GameModules.Launch) -> DirectX12Need? {
        if let traits, case .unsupported(.directX12) = BackendPlan.forTraits(traits) { return .directX12 }
        return module.requireBackend == .d3dmetal ? .gameSettings : nil
    }

    /// The need of a game in the library, or nil when D3DMetal is ready for it already. Reads the exe, and hashes
    /// it only when a module of the same name matches by SHA-256.
    public static func check(_ game: GameRecord, runtime: RuntimeManifest.Runtime, modules: [GameModule],
                             paths: AppPaths) -> DirectX12Need? {
        let info = try? ExecutableInfo.read(URL(filePath: game.executable))
        let module = (try? GameModules.resolve(game, info: info, runtime: runtime, modules: modules,
                                               app: GameModules.appVersion)?.launch.get()) ?? GameModules.Launch()
        guard let need = of(traits: info?.traits, module: module) else { return nil }
        return D3DMetal.isReady(paths: paths, runtime: runtime) ? nil : need
    }
}
