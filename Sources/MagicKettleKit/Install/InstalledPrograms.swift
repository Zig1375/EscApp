import Foundation

/// Finds the programs an installer put down and picks the one that starts the game, for the last install step
/// ("Which of them starts the game?").
///
/// Where they are: the folder Magic Kettle gave the installer, and anything new in the bottle's `drive_c` (installers
/// that ignore the folder use their own `C:\Program Files\…`). Which one starts the game: the target of a shortcut
/// the installer made, else the one named like the game, else the biggest.
public enum InstalledPrograms {
    public enum Role: String, Sendable, Equatable {
        case game
        /// A configuration or setup tool next to the game (`f2_res_config.exe`, `setsound.exe`).
        case settings
        /// Never offered: running it would remove the game.
        case uninstaller
        /// Runtimes installers carry along (DirectX, Visual C++, PhysX), never the game.
        case redistributable
    }

    public struct Program: Sendable, Equatable {
        public var url: URL
        public var role: Role
        /// An installer's shortcut points at it.
        public var hasShortcut: Bool
        public var size: Int
        /// The one to preselect.
        public var recommended = false

        public var name: String { url.lastPathComponent }
    }

    public struct Found: Sendable, Equatable {
        /// What the player chooses from, the recommended one first, settings tools last.
        public var programs: [Program]
        /// The uninstaller's name, for the hint that Magic Kettle leaves it out.
        public var uninstaller: String?

        public var recommended: Program? { programs.first { $0.recommended } }
    }

    static func role(ofFileNamed name: String, description: String = "", path: String = "") -> Role {
        let lower = name.lowercased()
        let base = (lower as NSString).deletingPathExtension
        if base.range(of: #"^unins\d*$"#, options: .regularExpression) != nil || base.hasPrefix("uninst")
            || base.hasPrefix("uninstall") || base.hasSuffix("uninstall") || description.contains("uninstall") {
            return .uninstaller
        }
        let redistributables = ["vcredist", "vc_redist", "dxsetup", "dxwebsetup", "directx", "dotnetfx", "ndp4",
                                "physx", "oalinst", "_commonredist", "redist"]
        let folders = path.lowercased()
        if redistributables.contains(where: { base.hasPrefix($0) || folders.contains("/\($0)") }) {
            return .redistributable
        }
        let settings = ["config", "setup", "settings", "setsound", "options", "configure", "register", "readme",
                        "update", "patch", "crashreport", "report"]
        if settings.contains(where: base.contains) { return .settings }
        return .game
    }

    /// - Parameters:
    ///   - folders: where the installer was told to install, and anything else to search (Mac paths).
    ///   - shortcutTargets: Mac paths of the programs the installer's new shortcuts point at.
    ///   - name: the game's name, to recognise its program among several.
    public static func find(in folders: [URL], shortcutTargets: [URL], name: String) -> Found {
        var seen = Set<String>()
        var programs: [Program] = []
        var uninstaller: String?
        let targets = Set(shortcutTargets.map { $0.standardizedFileURL.path.lowercased() })
        for folder in folders {
            for exe in executables(in: folder) where seen.insert(exe.standardizedFileURL.path.lowercased()).inserted {
                let info = try? ExecutableInfo.read(exe)
                let description = (info?.versionStrings["FileDescription"] ?? "").lowercased()
                let role = role(ofFileNamed: exe.lastPathComponent, description: description,
                                path: exe.deletingLastPathComponent().path(percentEncoded: false))
                if role == .uninstaller { uninstaller = uninstaller ?? exe.lastPathComponent }
                guard role == .game || role == .settings, info?.format == .pe32 || info?.format == .pe64 else {
                    continue
                }
                let size = (try? exe.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                programs.append(Program(url: exe, role: role,
                                        hasShortcut: targets.contains(exe.standardizedFileURL.path.lowercased()),
                                        size: size))
            }
        }
        rank(&programs, name: name)
        return Found(programs: programs, uninstaller: uninstaller)
    }

    private static func rank(_ programs: inout [Program], name: String) {
        let wanted = simplified(name)
        /// The game before settings tools; then a shortcut's target, then the one named like the game; then size.
        func score(_ program: Program) -> [Int] {
            let base = simplified((program.name as NSString).deletingPathExtension)
            let named = !wanted.isEmpty && !base.isEmpty && (wanted.contains(base) || base.contains(wanted))
            return [program.role == .game ? 1 : 0, program.hasShortcut ? 2 : named ? 1 : 0, program.size]
        }
        programs.sort { score($1).lexicographicallyPrecedes(score($0)) }
        if let first = programs.indices.first, programs[first].role == .game { programs[first].recommended = true }
    }

    private static func simplified(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// `.exe` files under `folder`, without following links: a bottle links `Documents` and `Desktop` to the
    /// Mac's own folders, and those are no installer's output.
    static func executables(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]) else { return [] }
        var result: [URL] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                walker.skipDescendants()
                continue
            }
            if values?.isRegularFile == true, url.pathExtension.lowercased() == "exe" { result.append(url) }
        }
        return result
    }

    /// Top-level folders of `drive_c` that the template doesn't have, and new folders inside its program folders:
    /// where an installer that ignored Magic Kettle's folder put the game.
    public static func newFolders(in bottle: URL, template: URL) -> [URL] {
        let fileManager = FileManager.default
        var result: [URL] = []
        let drive = bottle.appending(path: "drive_c")
        let templateDrive = template.appending(path: "drive_c")
        func newEntries(_ relative: String) -> [String] {
            let here = (try? fileManager.contentsOfDirectory(atPath: drive.appending(path: relative).path)) ?? []
            let there = Set(((try? fileManager.contentsOfDirectory(
                atPath: templateDrive.appending(path: relative).path)) ?? []).map { $0.lowercased() })
            return here.filter { !there.contains($0.lowercased()) && !$0.hasPrefix(".") }
        }
        for name in newEntries("") where BottleMigration.kind(of: drive.appending(path: name)) == .folder {
            result.append(drive.appending(path: name, directoryHint: .isDirectory))
        }
        for programs in ["Program Files", "Program Files (x86)"] {
            for name in newEntries(programs) {
                result.append(drive.appending(path: "\(programs)/\(name)", directoryHint: .isDirectory))
            }
        }
        return result
    }
}
