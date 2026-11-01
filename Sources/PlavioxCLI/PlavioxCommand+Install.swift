import Foundation
import PlavioxKit

extension PlavioxCommand {
    /// `plaviox install <setup.exe | game.msi | disc.iso>`: the app's install screens in one go. A disc image is
    /// attached and its installer run from drive D:; the recommended program becomes the game unless
    /// `--program` names another.
    func install(_ arguments: [String]) async -> Output {
        var options = Options(arguments)
        let folderValue = options.value("--folder")
        let nameValue = options.value("--name")
        let programValue = options.value("--program")
        let ejectDisc = options.flag("--eject")
        guard let path = options.positional() else { return failure("install needs a setup.exe, .msi or disc image") }
        if let unknown = options.leftover { return failure("Unknown option: \(unknown)") }
        let file = URL(filePath: path).standardizedFileURL

        var disc: MountedDisc?
        do {
            guard let runtime = try manifest().newest(forApp: Self.appVersion, macOS: Self.macOSVersion) else {
                return failure("No runtime suits this Mac.")
            }
            let installer: URL
            (installer, disc) = try await installerToRun(file)
            guard let kind = InstallerKind.detect(installer) else {
                if let disc { await DiscImage.detach(disc) }
                return failure("\(installer.lastPathComponent) doesn't look like an installer. Use: plaviox run")
            }
            let gameInstaller = GameInstaller(paths: paths, host: host)
            let name = nameValue ?? GameInstaller.suggestedName(installer: installer, disc: disc?.image)
            let folder = folderValue.map { URL(filePath: $0, directoryHint: .isDirectory) }
                ?? gameInstaller.defaultFolder(for: name)
            let plan = GameInstaller.Plan(installer: installer, kind: kind, name: name, folder: folder, disc: disc)
            let installed = try await gameInstaller.install(plan, runtime: runtime, progress: report(plan))
            let result = try finishInstall(installed, with: gameInstaller, program: programValue,
                                           keepDisc: disc != nil && !ejectDisc)
            if let disc { await DiscImage.detach(disc) }
            return result
        } catch {
            if let disc { await DiscImage.detach(disc) }
            return failure("\(error)")
        }
    }

    /// The installer itself, or the one on a disc image, which is attached first.
    private func installerToRun(_ file: URL) async throws -> (URL, MountedDisc?) {
        guard DiscImage.isImage(file) else { return (file, nil) }
        let disc = try await DiscImage.attach(file, paths: paths)
        let contents = DiscContents.read(disc.mountPoint)
        progress("Disc \(file.lastPathComponent) is in drive D:. Folders: "
            + (contents.folders.isEmpty ? "none" : contents.folders.joined(separator: ", ")))
        guard let found = contents.installer else {
            await DiscImage.detach(disc)
            throw CLIError("There's no installer on this disc.")
        }
        return (found.url, disc)
    }

    private func report(_ plan: GameInstaller.Plan) -> @Sendable (GameInstaller.Step) -> Void {
        let progress = progress
        let target = plan.kind.takesFolder ? " into \(plan.folder.path(percentEncoded: false))…" : "…"
        let name = plan.installer.lastPathComponent
        return { step in
            switch step {
            case let .windows(firstTime): if firstTime { progress("Setting up Windows (once)…") }
            case .installing: progress("Running \(name) (\(plan.kind.rawValue))\(target)")
            case .findingGame: progress("Looking for the game's program…")
            }
        }
    }

    private func finishInstall(_ installed: GameInstaller.Installed, with installer: GameInstaller, program: String?,
                               keepDisc: Bool) throws -> Output {
        let programs = installed.found.programs
        let lines = programs.map { program in
            let tags = [program.recommended ? "recommended" : nil, program.role == .settings ? "settings" : nil,
                        program.hasShortcut ? "shortcut" : nil].compactMap { $0 }
            let path = "  \(program.url.path(percentEncoded: false))"
            return tags.isEmpty ? path : "\(path)  [\(tags.joined(separator: ", "))]"
        }
        let log = "Log: \(installed.log.path(percentEncoded: false))"
        let chosen = program.map { name in programs.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
            ?? installed.found.recommended
        guard let chosen else {
            installer.cancel(installed.id)
            let reason = programs.isEmpty ? "The installer didn't install any program."
                : "No program called \(program ?? "")."
            return failure(([reason] + lines + [log]).joined(separator: "\n"))
        }
        let record = try installer.finish(installed, program: chosen.url, keepDisc: keepDisc)
        var summary = ["Installed \(record.name) (\(record.id)).", "Programs:"] + lines
        if let uninstaller = installed.found.uninstaller { summary.append("Left out: \(uninstaller)") }
        summary += ["Plays: \(record.executable)",
                    record.disc.map { "Disc in D: on every launch: \($0)" } ?? "No disc", log]
        return success(summary.joined(separator: "\n"))
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
