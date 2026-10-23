import EscAppKit
import Foundation

/// `escapp game …`, `escapp inspect` and `escapp run`.
extension EscAppCommand {
    func game(_ arguments: [String]) async -> Output {
        var options = Options(arguments)
        guard let action = options.positional() else { return failure("game needs identify, prepare or list") }
        if action == "list" { return gameList() }
        guard action == "identify" || action == "prepare" else { return failure("Unknown game action: \(action)") }

        let windowsValue = options.value("--windows")
        guard let path = options.positional() else { return failure("game \(action) needs the path to an .exe") }
        if let unknown = options.leftover { return failure("Unknown option: \(unknown)") }
        let windows = windowsValue.flatMap(WindowsVersion.init(wineValue:))
        if let windowsValue, windows == nil {
            return failure("Unknown Windows version: \(windowsValue). Use winxp, win7, win10 or win11.")
        }
        guard FileManager.default.fileExists(atPath: path) else { return failure("No such file: \(path)") }

        do {
            let result = try GameIdentifier(paths: paths).identify(executable: URL(filePath: path))
            let summary = [
                "Game: \(result.record.name) (\(result.record.id))",
                "Found by: \(result.method.rawValue)",
                "Folder: \(result.record.folder)",
            ]
            guard action == "prepare" else { return success(summary.joined(separator: "\n")) }
            return try await gamePrepare(result.record, windows: windows, summary: summary)
        } catch {
            return failure("\(error)")
        }
    }

    func inspect(_ arguments: [String]) -> Output {
        guard let path = arguments.first, arguments.count == 1 else { return failure("inspect needs one .exe") }
        do {
            let info = try ExecutableInfo.read(URL(filePath: path))
            let plan: String = switch BackendPlan.forTraits(info.traits) {
            case let .attempts(backends): backends.map(\.displayName).joined(separator: " → ")
            case let .unsupported(reason): "not supported (\(reason))"
            }
            let directX = info.directX.sorted().map { $0 == .legacy ? "DirectDraw/D3D8" : "D3D\($0.rawValue)" }
            return success([
                "Format: \(info.format.rawValue)",
                "Name: \(info.productName ?? "-")",
                "DirectX: \(directX.isEmpty ? "-" : directX.joined(separator: ", "))",
                "High DPI: \(info.dpiAware ? "yes" : "no")",
                "Icon: \(info.icon.map { "\($0.count) bytes" } ?? "-")",
                "Graphics plan: \(plan)",
                "Imports: \(info.imports.sorted().joined(separator: " "))",
            ].joined(separator: "\n"))
        } catch {
            return failure("\(error)")
        }
    }

    func runGame(_ arguments: [String]) async -> Output {
        var options = Options(arguments)
        let backendValue = options.value("--backend")
        let verbose = options.flag("--verbose")
        let noRetry = options.flag("--no-retry")
        guard let path = options.positional() else { return failure("run needs the path to an .exe") }
        if let unknown = options.leftover { return failure("Unknown option: \(unknown)") }
        let backend = backendValue.flatMap(GraphicsBackend.init(rawValue:))
        if let backendValue, backend == nil { return failure("Unknown backend: \(backendValue)") }

        do {
            guard let runtime = try manifest().newest(forApp: Self.appVersion, macOS: Self.macOSVersion) else {
                return failure("No runtime suits this Mac.")
            }
            let manifest = try manifest()
            let game = try GameIdentifier(paths: paths).identify(executable: URL(filePath: path)).record
            let progress = progress
            let result = try await AutoLaunch(paths: paths, host: host).play(
                game, runtime: runtime, backend: backend, knownGames: manifest.games ?? [], verboseLog: verbose,
                control: control(noRetry: noRetry)) { event in
                switch event {
                case let .started(_, backend, attempt, total):
                    progress("Starting \(game.name) with \(backend.displayName) (attempt \(attempt) of \(total))…")
                case let .retrying(failed, next, _, _):
                    progress("\(Self.describe(failed)). Trying \(next.displayName).")
                case let .working(backend, _):
                    progress("\(backend.displayName) works; the game keeps running.")
                case .windowShown:
                    progress("The game's window is up.")
                case .preparing:
                    break
                }
            }
            let lines = result.attempts.map { Self.describe($0) } + [
                result.working.map { "Works with \($0.displayName)." } ?? "Didn't start with any backend.",
                "Log: \(result.log?.path ?? "-")",
            ]
            return result.working == nil ? failure(lines.joined(separator: "\n"))
                : success(lines.joined(separator: "\n"))
        } catch {
            return failure("\(error)")
        }
    }

    private func control(noRetry: Bool) -> LaunchControl {
        let control = LaunchControl()
        if noRetry { control.stopRetrying() }
        return control
    }

    static func describe(_ attempt: LaunchAttempt) -> String {
        let result: String = switch attempt.failure {
        case nil: "worked"
        case let .closed(code)?: "closed after \(attempt.seconds) s (exit \(code))"
        case .noWindow?: "showed no window in \(attempt.seconds) s"
        }
        let problem = attempt.diagnosis.problem.map { " — \($0)" } ?? ""
        return "\(attempt.backend.displayName): \(result)\(attempt.failure == nil ? "" : problem)"
    }

    func gameList() -> Output {
        guard let library = try? GameLibrary.load(from: paths.library) else { return failure("Can't read Games.json") }
        let lines = library.games.map { "\($0.id)  \($0.name)  \($0.windowsVersion.displayName)  \($0.executable)" }
        return success(lines.isEmpty ? "No games yet." : lines.joined(separator: "\n"))
    }

    func gamePrepare(_ game: GameRecord, windows: WindowsVersion?, summary: [String]) async throws -> Output {
        guard let runtime = try manifest().newest(forApp: Self.appVersion, macOS: Self.macOSVersion),
              RuntimeInstaller(paths: paths).installed(runtime) != nil
        else { return failure("The runtime isn't installed. Run: escapp runtime install") }
        var record = game
        if let windows {
            record.windowsVersion = windows
            var library = try GameLibrary.load(from: paths.library)
            library[record.id] = record
            try library.save(to: paths.library)
        }
        let bottles = BottleManager(paths: paths, host: host)
        if !bottles.hasTemplate(for: runtime) { progress("Setting up Windows for \(runtime.id) (once)…") }
        let bottle = try await bottles.ensureBottle(for: record.id, runtime: runtime, windows: record.windowsVersion)
        let lines = summary + [
            "Windows: \(BottleManager.windowsVersion(of: bottle).displayName)",
            "Bottle: \(bottle.path(percentEncoded: false))",
        ]
        return success(lines.joined(separator: "\n"))
    }
}
