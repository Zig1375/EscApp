import Foundation
import PlavioxKit

/// `plaviox game …`, `plaviox inspect` and `plaviox run`.
extension PlavioxCommand {
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
            let result = try identify(path)
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
            let folder = URL(filePath: path).deletingLastPathComponent()
            let rpgMaker = RPGMakerGame.read(folder: folder).map { game in
                let rtps = game.rtps.isEmpty ? "no package" : game.rtps.joined(separator: ", ")
                let screen = game.screen.map { "\($0.width)×\($0.height)" } ?? "size unknown"
                return "\(game.engine.rawValue), \(rtps), \(screen)"
            }
            let known = (try? manifest())?.redists ?? []
            let redists = RedistNeeds.read(executable: URL(filePath: path), info: info)
                .map { RedistNeeds.needed($0, from: known).map(\.id) } ?? []
            return success([
                "Format: \(info.format.rawValue)",
                "Name: \(info.productName ?? "-")",
                "DirectX: \(directX.isEmpty ? "-" : directX.joined(separator: ", "))",
                "High DPI: \(info.dpiAware ? "yes" : "no")",
                "Chromium: \(info.chromium ? "yes" : "no")",
                "Icon: \(info.icon.map { "\($0.count) bytes" } ?? "-")",
                "Graphics plan: \(plan)",
                "RPG Maker: \(rpgMaker ?? "-")",
                "Language: \(GameLanguage.locale(forGameIn: folder) ?? "the Mac's")",
                "Microsoft runtimes: \(redists.isEmpty ? "-" : redists.joined(separator: ", "))",
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
        let scaleValue = options.value("--scale")
        let discValue = options.value("--disc")
        guard let path = options.positional() else { return failure("run needs the path to an .exe") }
        if let unknown = options.leftover { return failure("Unknown option: \(unknown)") }

        do {
            let backend: GraphicsBackend? = try choice(backendValue, "backend")
            let scaling: GameScaling.Setting? = try choice(scaleValue, "scaling")
            guard let runtime = try manifest().newest(forApp: Self.appVersion, macOS: Self.macOSVersion) else {
                return failure("No runtime suits this Mac.")
            }
            let manifest = try manifest()
            let game = try identified(path, scaling: scaling, disc: discValue)
            let progress = progress
            let result = try await AutoLaunch(paths: paths, host: host).play(
                game, runtime: runtime, backend: backend, knownGames: manifest.games ?? [], verboseLog: verbose,
                control: control(noRetry: noRetry)) { event in
                if let line = Self.describe(event, game: game.name) { progress(line) }
            }
            // With --backend or --no-retry the run isn't judged: it ran unless it failed.
            let ran = result.working != nil || (backend != nil || noRetry) && result.attempts.last?.failure == nil
            let verdict = result.working.map { "Works with \($0.displayName)." }
                ?? (ran ? "Ran without checking." : "Didn't start with any backend.")
            let judged = result.working != nil
            let lines = result.attempts.map { Self.describe($0, judged: judged) }
                + [verdict, "Log: \(result.log?.path ?? "-")"]
            return ran ? success(lines.joined(separator: "\n")) : failure(lines.joined(separator: "\n"))
        } catch {
            return failure("\(error)")
        }
    }

    /// What `run` prints as the launch goes; nil for the steps it keeps quiet about.
    static func describe(_ event: AutoLaunch.Event, game: String) -> String? {
        switch event {
        case let .started(_, backend, attempt, total):
            "Starting \(game) with \(backend.displayName) (attempt \(attempt) of \(total))…"
        case let .retrying(failed, next, _, _):
            "\(describe(failed)). Trying \(next.displayName)."
        case let .working(backend, _):
            "\(backend.displayName) works; the game keeps running."
        case .windowShown:
            "The game's window is up."
        case let .asksForDisc(text):
            "The game asks for its CD (\"\(text)\"). Give it one with --disc <image>."
        case let .tuning(order):
            "First launch: looking for settings that work, trying \(order.map(\.displayName).joined(separator: ", "))."
        case let .preparing(.component(component)):
            component.phase == .installing
                ? "Installing \(component.name) (\(component.number) of \(component.count))…" : nil
        case .preparing, .checking:
            nil
        }
    }

    /// An option's value as one of its choices; nil when the option wasn't given.
    private func choice<Value: RawRepresentable>(_ value: String?, _ name: String) throws -> Value?
        where Value.RawValue == String {
        guard let value else { return nil }
        guard let choice = Value(rawValue: value) else { throw CLIError("Unknown \(name): \(value)") }
        return choice
    }

    /// The game the exe belongs to, with `--scale` and `--disc` kept for it like the app's settings.
    private func identified(_ path: String, scaling: GameScaling.Setting?, disc: String?) throws -> GameRecord {
        var game = try identify(path).record
        guard scaling != nil || disc != nil else { return game }
        if let scaling { game.scaling = scaling == .auto ? nil : scaling }
        if let disc { game.disc = URL(filePath: disc).standardizedFileURL.path(percentEncoded: false) }
        let record = game
        try GameLibrary.modify(paths.library) { $0[record.id] = record }
        return record
    }

    /// The game the exe belongs to. A store's game is the record the app keeps for it, launched through its
    /// client; the store's games are read first, as the app does, so one installed a moment ago is known too.
    private func identify(_ path: String) throws -> GameIdentifier.Result {
        let identifier = GameIdentifier(paths: paths)
        let exe = URL(filePath: path)
        if identifier.storeBottle(containing: exe) != nil { try StoreLibrary.sync(paths: paths) }
        return try identifier.identify(executable: exe)
    }

    private func control(noRetry: Bool) -> LaunchControl {
        let control = LaunchControl()
        if noRetry { control.stopRetrying() }
        return control
    }

    /// - Parameter judged: whether the run checked the game's window. A run with `--backend` isn't checked;
    ///   "worked" for those read as if the game had been seen working.
    static func describe(_ attempt: LaunchAttempt, judged: Bool = true) -> String {
        let result: String = switch attempt.failure {
        case nil: judged ? "worked" : "ran, not checked"
        case let .closed(code)?: "closed after \(attempt.seconds) s (exit \(code))"
        case .noWindow?: "showed no window in \(attempt.seconds) s"
        case .blankPicture?: "its window stayed blank"
        case .frozen?: "its picture froze on a blank window"
        case .noWebGL?: "its graphics didn't start (WebGL refused)"
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
        else { return failure("The runtime isn't installed. Run: plaviox runtime install") }
        var record = game
        // A store game runs in its store's bottle, whose Windows version is the store's.
        if windows != nil, let store = game.store {
            return failure("\(game.name) runs in \(store.name)'s Windows, which keeps its own version.")
        }
        if let windows {
            record.windowsVersion = windows
            try GameLibrary.modify(paths.library) { $0[record.id] = record }
        }
        let bottles = BottleManager(paths: paths, host: host)
        if !bottles.hasTemplate(for: runtime) { progress("Setting up Windows for \(runtime.id) (once)…") }
        let bottle = try await bottles.ensureBottle(for: record.bottleID, runtime: runtime,
                                                    windows: record.store == nil ? record.windowsVersion : .default)
        let lines = summary + [
            "Windows: \(BottleManager.windowsVersion(of: bottle).displayName)",
            "Bottle: \(bottle.path(percentEncoded: false))",
        ]
        return success(lines.joined(separator: "\n"))
    }
}
