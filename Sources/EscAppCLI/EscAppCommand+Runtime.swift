import EscAppKit
import Foundation

/// `escapp runtime status|install`.
extension EscAppCommand {
    func runtime(_ arguments: [String]) async -> Output {
        var options = Options(arguments)
        guard let action = options.positional() else { return failure("runtime needs status or install") }
        let acceptRosetta = options.flag("--accept-rosetta-license")
        if let unknown = options.leftover { return failure("Unknown option: \(unknown)") }

        let selected: RuntimeManifest.Runtime
        do {
            guard let runtime = try manifest().newest(forApp: Self.appVersion, macOS: Self.macOSVersion) else {
                return failure("No runtime in the component list supports this Mac and this version of EscApp.")
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

    func runtimeStatus(_ selected: RuntimeManifest.Runtime) -> Output {
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

    func runtimeInstall(_ selected: RuntimeManifest.Runtime, acceptRosetta: Bool) async -> Output {
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
}
