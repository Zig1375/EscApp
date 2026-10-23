import Foundation
import RumKit

/// `rum`: a debugging tool that shows what the app would do. It never changes the user's games or settings.
public struct RumCommand {
    public static let version = "0.1.0"

    public struct Output: Equatable, Sendable {
        public var stdout: String
        public var stderr: String
        public var status: Int32
    }

    let paths: RumPaths
    let host: [String: String]

    public init(paths: RumPaths = .standard(), host: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.host = host
    }

    public func run(_ arguments: [String]) -> Output {
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

    var leftover: String? { arguments.first }
}
