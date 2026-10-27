import EscAppKit
import Foundation

/// `escapp module list|show|update`: the game modules EscApp has and what one does to a game's launch.
extension EscAppCommand {
    func module(_ arguments: [String]) async -> Output {
        var options = Options(arguments)
        guard let action = options.positional() else { return failure("module needs list, show or update") }
        let target = options.positional()
        if let unknown = options.leftover { return failure("Unknown option: \(unknown)") }
        let updater = GameModulesUpdater(paths: paths)
        switch action {
        case "list":
            return success(Self.describe(updater.current(), cached: updater.cached()?.checkedAt))
        case "update":
            do {
                return success(Self.describe(try await updater.check(), cached: Date()))
            } catch {
                return failure("Couldn't fetch the game modules: \(error)")
            }
        case "show":
            guard let target else { return failure("module show needs a game id or an .exe") }
            return moduleShow(target, index: updater.current())
        default:
            return failure("Unknown module action: \(action). Use list, show or update.")
        }
    }

    static func describe(_ index: GameModuleIndex, cached: Date?) -> String {
        let generated = index.generated.map { $0.formatted(.iso8601) } ?? "unknown"
        var lines = ["Index \(generated) (\(index.commit ?? "no commit")), \(index.modules.count) games"]
        if let cached { lines.append("Last fetched \(cached.formatted(.iso8601))") }
        lines += index.modules.map { "  \($0.id) revision \($0.revision): \($0.name)" }
        return lines.joined(separator: "\n")
    }

    func moduleShow(_ target: String, index: GameModuleIndex) -> Output {
        let library = (try? GameLibrary.load(from: paths.library)) ?? GameLibrary()
        let record: GameRecord
        if let game = library.games.first(where: { $0.id.rawValue == target.uppercased() }) {
            record = game
        } else if FileManager.default.fileExists(atPath: target) {
            let exe = URL(filePath: target).standardizedFileURL
            record = library.games.first { $0.executable == exe.path }
                ?? GameRecord(id: GameID.make(), name: exe.deletingPathExtension().lastPathComponent,
                              executable: exe.path, folder: exe.deletingLastPathComponent().path, hasMarker: false,
                              addedAt: Date())
        } else {
            return failure("No game with id \(target), and no such file")
        }
        guard let runtime = try? manifest().newest(forApp: Self.appVersion, macOS: Self.macOSVersion) else {
            return failure("No runtime in the component list supports this Mac and this version of EscApp.")
        }
        let info = try? ExecutableInfo.read(URL(filePath: record.executable))
        guard let (module, launch) = GameModules.resolve(record, info: info, runtime: runtime,
                                                         modules: index.modules, app: nil) else {
            return success("\(record.name): no game settings")
        }
        var lines = ["\(record.name): \(module.id) revision \(module.revision)"]
        switch launch {
        case let .success(settings):
            if !settings.preferBackends.isEmpty {
                lines.append("  graphics first: \(settings.preferBackends.map(\.rawValue).joined(separator: ", "))")
            }
            if let backend = settings.requireBackend { lines.append("  graphics only: \(backend.rawValue)") }
            if let windows = settings.requireWindows ?? settings.preferWindows {
                lines.append("  Windows: \(windows.wineValue)")
            }
            if settings.isEmpty { lines.append("  nothing for this launch") }
        case let .failure(.wine(installed)):
            lines.append("  not applied: needs another Wine than \(installed)")
        }
        return success(lines.joined(separator: "\n"))
    }
}
