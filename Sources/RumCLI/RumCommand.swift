import Foundation
import RumKit

/// `rum`: a debugging tool that shows what the app would do. It never touches games or settings;
/// `runtime install` installs components exactly as the app's setup screen does.
public struct RumCommand: Sendable {
    public static let version = "0.1.0"

    public struct Output: Equatable, Sendable {
        public var stdout: String
        public var stderr: String
        public var status: Int32
    }

    let paths: RumPaths
    let host: [String: String]
    let manifest: @Sendable () throws -> RuntimeManifest
    let rosettaInstalled: @Sendable () -> Bool
    /// Live progress lines for long commands; the CLI prints them to stderr as they come.
    let progress: @Sendable (String) -> Void

    public init(
        paths: RumPaths = .standard(),
        host: [String: String] = ProcessInfo.processInfo.environment,
        manifest: @escaping @Sendable () throws -> RuntimeManifest = { try RuntimeManifest.bundled() },
        rosettaInstalled: @escaping @Sendable () -> Bool = { Rosetta.isInstalled() },
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.paths = paths
        self.host = host
        self.manifest = manifest
        self.rosettaInstalled = rosettaInstalled
        self.progress = progress
    }

    public func run(_ arguments: [String]) async -> Output {
        guard let command = arguments.first else { return failure(Self.usage) }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "version", "--version":
            return success(Self.version)
        case "paths":
            return success(pathsReport())
        case "plan":
            return plan(rest)
        case "env":
            return env(rest)
        case "runtime":
            return await runtime(rest)
        case "help", "--help", "-h":
            return success(Self.usage)
        default:
            return failure("Unknown command: \(command)\n\n\(Self.usage)")
        }
    }

    static let usage = """
        Usage: rum <command>

          version                          Print the version
          paths                            Show where Rum keeps its files (RUM_HOME overrides)
          plan --arch x86|x64 [--dx 8|9|11|12 ...] [--launcher]
                                           Show which graphics backends a first launch would try
          env --bottle <path> --backend dxvk|dxmt|wined3d [--verbose]
                                           Print the environment a game would start with
          runtime status                   Show Rosetta and whether the current runtime is installed
          runtime install [--accept-rosetta-license]
                                           Download, check and install Wine, DXVK and DXMT
        """

    private func pathsReport() -> String {
        [
            ("Root", paths.root), ("Runtimes", paths.runtimes), ("Templates", paths.templates),
            ("Bottles", paths.bottles), ("Profile", paths.profile), ("Logs", paths.logs),
            ("Library", paths.library), ("Games (G:)", paths.games),
        ]
        .map { "\($0.0): \($0.1.path(percentEncoded: false))" }
        .joined(separator: "\n")
    }

    private func plan(_ arguments: [String]) -> Output {
        var options = Options(arguments)
        guard let archValue = options.value("--arch"),
              let architecture = ExecutableTraits.Architecture(rawValue: archValue)
        else { return failure("plan needs --arch x86 or --arch x64") }
        var directX = Set<ExecutableTraits.DirectX>()
        while let value = options.value("--dx") {
            guard let number = Int(value), let dx = Self.directX(number) else {
                return failure("Unknown DirectX version: \(value). Use 8, 9, 11 or 12.")
            }
            directX.insert(dx)
        }
        let launcher = options.flag("--launcher")
        if let unknown = options.leftover { return failure("Unknown option: \(unknown)") }

        let traits = ExecutableTraits(architecture: architecture, directX: directX, isChromiumLauncher: launcher)
        switch BackendPlan.forTraits(traits) {
        case let .attempts(backends):
            return success(backends.map(\.displayName).joined(separator: " → "))
        case .unsupported(.sixteenBit):
            return failure("16-bit programs can't run on this Mac.")
        case .unsupported(.directX12):
            return failure("DirectX 12 games aren't supported yet.")
        }
    }

    private func env(_ arguments: [String]) -> Output {
        var options = Options(arguments)
        guard let bottle = options.value("--bottle") else { return failure("env needs --bottle <path>") }
        guard let backendValue = options.value("--backend"),
              let backend = GraphicsBackend(rawValue: backendValue)
        else { return failure("env needs --backend dxvk, dxmt or wined3d") }
        let verbose = options.flag("--verbose")
        if let unknown = options.leftover { return failure("Unknown option: \(unknown)") }

        let environment = WineEnvironment.make(host: host, bottle: bottle, backend: backend, verboseLog: verbose)
        return success(environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
    }

    private func runtime(_ arguments: [String]) async -> Output {
        var options = Options(arguments)
        guard let action = options.positional() else { return failure("runtime needs status or install") }
        let acceptRosetta = options.flag("--accept-rosetta-license")
        if let unknown = options.leftover { return failure("Unknown option: \(unknown)") }

        let selected: RuntimeManifest.Runtime
        do {
            guard let runtime = try manifest().newest(forRum: Self.rumVersion, macOS: Self.macOSVersion) else {
                return failure("No runtime in the component list supports this Mac and this version of Rum.")
            }
            selected = runtime
        } catch {
            return failure("\(error)")
        }
        switch action {
        case "status": return runtimeStatus(selected)
        case "install": return await runtimeInstall(selected, acceptRosetta: acceptRosetta)
        default: return failure("Unknown runtime action: \(action). Use status or install.")
        }
    }

    private func runtimeStatus(_ selected: RuntimeManifest.Runtime) -> Output {
        let installer = RuntimeInstaller(paths: paths)
        var lines = ["Rosetta: \(rosettaInstalled() ? "installed" : "not installed")"]
        if let folder = installer.installed(selected) {
            lines.append("Runtime \(selected.id): installed in \(folder.path(percentEncoded: false))")
        } else {
            let total = selected.components.reduce(0) { $0 + $1.size }
            lines.append("Runtime \(selected.id): not installed (\(Self.megabytes(total)) to download)")
        }
        lines += selected.components.map { "  \($0.kind.rawValue) \($0.version) (\($0.license))" }
        return success(lines.joined(separator: "\n"))
    }

    private func runtimeInstall(_ selected: RuntimeManifest.Runtime, acceptRosetta: Bool) async -> Output {
        if !rosettaInstalled() {
            guard acceptRosetta else {
                return failure("""
                    Wine needs Rosetta 2. Installing it means accepting Apple's license \
                    (https://www.apple.com/legal/sla/). Run again with --accept-rosetta-license to do that.
                    """)
            }
            progress("Installing Rosetta…")
            do { try await Rosetta.installAcceptingLicense() } catch { return failure("\(error)") }
        }
        let reporter = ProgressReporter(sink: progress)
        do {
            let folder = try await RuntimeInstaller(paths: paths).install(selected) { reporter.report($0) }
            return success("Runtime \(selected.id) installed in \(folder.path(percentEncoded: false))")
        } catch {
            return failure("\(error)")
        }
    }

    static let rumVersion = Version(version) ?? .zero
    static var macOSVersion: Version {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return Version("\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)") ?? .zero
    }

    static func megabytes(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
    }

    private static func directX(_ number: Int) -> ExecutableTraits.DirectX? {
        switch number {
        case 1...8: .legacy
        case 9: .d3d9
        case 10, 11: .d3d11
        case 12: .d3d12
        default: nil
        }
    }

    private func success(_ text: String) -> Output { Output(stdout: text + "\n", stderr: "", status: 0) }
    private func failure(_ text: String) -> Output { Output(stdout: "", stderr: text + "\n", status: 1) }
}

/// Just enough option parsing for a handful of commands; not worth a dependency.
private struct Options {
    private var arguments: [String]

    init(_ arguments: [String]) { self.arguments = arguments }

    /// Removes and returns the value after the first `name`.
    mutating func value(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
        return value
    }

    mutating func flag(_ name: String) -> Bool {
        guard let index = arguments.firstIndex(of: name) else { return false }
        arguments.remove(at: index)
        return true
    }

    /// Removes and returns the first argument that isn't an option.
    mutating func positional() -> String? {
        guard let index = arguments.firstIndex(where: { !$0.hasPrefix("-") }) else { return nil }
        return arguments.remove(at: index)
    }

    var leftover: String? { arguments.first }
}

/// Turns installer steps into a line per component phase and every 10% of a download, not one per chunk.
private final class ProgressReporter: @unchecked Sendable {
    private let sink: @Sendable (String) -> Void
    private let lock = NSLock()
    private var lastLine = ""

    init(sink: @escaping @Sendable (String) -> Void) { self.sink = sink }

    func report(_ step: RuntimeInstaller.Step) {
        let line: String
        switch step {
        case let .downloading(kind, received, total):
            let percent = total > 0 ? received * 10 / total * 10 : 0
            line = "Downloading \(kind.rawValue): \(percent)% of \(RumCommand.megabytes(total))"
        case let .unpacking(kind): line = "Unpacking \(kind.rawValue)…"
        case .finishing: line = "Finishing…"
        }
        let changed = lock.withLock {
            guard line != lastLine else { return false }
            lastLine = line
            return true
        }
        if changed { sink(line) }
    }
}
