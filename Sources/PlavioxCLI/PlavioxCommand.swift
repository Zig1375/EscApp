import Foundation
import PlavioxKit

/// `plaviox`: a debugging tool that shows what the app would do. It never touches games or settings;
/// `runtime install` installs components exactly as the app's setup screen does.
public struct PlavioxCommand: Sendable {
    public static let version = "1.0"

    public struct Output: Equatable, Sendable {
        public var stdout: String
        public var stderr: String
        public var status: Int32
    }

    let paths: AppPaths
    let host: [String: String]
    let manifest: @Sendable () throws -> RuntimeManifest
    let rosettaInstalled: @Sendable () -> Bool
    /// Live progress lines for long commands; the CLI prints them to stderr as they come.
    let progress: @Sendable (String) -> Void

    public init(
        paths: AppPaths = .standard(),
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
        case "runtime", "d3dmetal":
            return command == "runtime" ? await runtime(rest) : await d3dmetal(rest)
        case "game", "module":
            return command == "game" ? await game(rest) : await module(rest)
        case "inspect", "store":
            return command == "inspect" ? inspect(rest) : await store(rest)
        case "run", "install":
            return command == "run" ? await runGame(rest) : await install(rest)
        default:
            let isHelp = ["help", "--help", "-h"].contains(command)
            return isHelp ? success(Self.usage) : failure("Unknown command: \(command)\n\n\(Self.usage)")
        }
    }

    static let usage = """
        Usage: plaviox <command>

          version                          Print the version
          paths                            Show where Plaviox keeps its files (PLAVIOX_HOME overrides)
          plan --arch x86|x64 [--dx 8|9|11|12 ...] [--launcher] [--chromium]
                                           Show which graphics backends a first launch would try
          env --bottle <path> [--verbose]
                                           Print the environment a game would start with
          runtime status                   Show Rosetta and whether the current runtime is installed
          runtime install [--accept-rosetta-license]
                                           Download, check and install Wine, DXVK and DXMT
          d3dmetal status|remove           Show or remove D3DMetal, which runs DirectX 12 games
          d3dmetal import <dmg> [--accept-apple-license]
                                           Add D3DMetal from Apple's "Evaluation environment for Windows
                                           games" disk image, after checking Apple's signature
          game identify <exe>              Show which game an .exe belongs to (creates its .plaviox)
          game prepare <exe> [--windows winxp|win7|win10|win11]
                                           Identify the game and make its bottle (needs the runtime)
          game list                        List known games
          module list|update               Show the game settings Plaviox has, or fetch the newest
          module show <game id|exe>        Show the settings Plaviox has for a game
          inspect <exe>                    Show what Plaviox reads from an .exe: format, DirectX, name, icon
          store list                       Show which stores are installed and running
          store install|open|close|remove steam|epic
                                           Install a store's client in its own bottle, open it, close it,
                                           or remove it with its games
          store sync                       Add the stores' installed games to the library and list them
          run <exe> [--backend dxvk|dxmt|wined3d|d3dmetal] [--no-retry] [--verbose] [--scale auto|on|off]
              [--disc <image>]
                                           Launch a game like the app does, trying the next backend when it
                                           fails at start, and wait until it closes
          install <setup.exe|.msi|.iso> [--folder <path>] [--name <name>] [--program <exe>] [--eject]
                                           Install a game like the app does: from a disc image, its installer
                                           runs from drive D: and the disc stays in for the game (--eject: not)
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
        let chromium = options.flag("--chromium")
        if let unknown = options.leftover { return failure("Unknown option: \(unknown)") }

        let traits = ExecutableTraits(architecture: architecture, directX: directX, isChromiumLauncher: launcher,
                                     isChromium: chromium)
        switch BackendPlan.forTraits(traits) {
        case let .attempts(backends):
            return success(backends.map(\.displayName).joined(separator: " → "))
        case .unsupported(.sixteenBit):
            return failure("16-bit programs can't run on this Mac.")
        case .unsupported(.directX12):
            return failure("DirectX 12 games need D3DMetal: plaviox d3dmetal import <dmg>")
        }
    }

    private func env(_ arguments: [String]) -> Output {
        var options = Options(arguments)
        guard let bottle = options.value("--bottle") else { return failure("env needs --bottle <path>") }
        let verbose = options.flag("--verbose")
        if let unknown = options.leftover { return failure("Unknown option: \(unknown)") }

        let environment = WineEnvironment.make(host: host, bottle: bottle, verboseLog: verbose)
        return success(environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
    }

    static let appVersion = Version(version) ?? .zero
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

    func success(_ text: String) -> Output { Output(stdout: text + "\n", stderr: "", status: 0) }
    func failure(_ text: String) -> Output { Output(stdout: "", stderr: text + "\n", status: 1) }
}

/// Just enough option parsing for a handful of commands; not worth a dependency.
struct Options {
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
final class ProgressReporter: @unchecked Sendable {
    private let sink: @Sendable (String) -> Void
    private let lock = NSLock()
    private var lastLine = ""

    init(sink: @escaping @Sendable (String) -> Void) { self.sink = sink }

    func report(_ step: RuntimeInstaller.Step) {
        let line: String
        switch step {
        case let .downloading(kind, received, total):
            let percent = total > 0 ? received * 10 / total * 10 : 0
            line = "Downloading \(kind.rawValue): \(percent)% of \(PlavioxCommand.megabytes(total))"
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
