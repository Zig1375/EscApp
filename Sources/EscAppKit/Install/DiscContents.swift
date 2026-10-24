import Foundation

/// What is on a game's CD, for the first install step: its installer, its disc menu (`AUTORUN.EXE`), its folders.
public struct DiscContents: Sendable, Equatable {
    public struct Program: Sendable, Equatable {
        public var url: URL
        /// Nil for a program that is neither installer nor disc menu.
        public var installer: InstallerKind?
        public var isMenu: Bool

        public var name: String { url.lastPathComponent }
    }

    /// Installers first (the one to use first of all), then the disc menu, then other programs.
    public var programs: [Program]
    /// Folder names at the top of the disc.
    public var folders: [String]

    public var installer: Program? { programs.first { $0.installer != nil } }

    /// Reads the top of the disc, and one folder down for an installer kept in `SETUP\` or `INSTALL\`.
    public static func read(_ root: URL) -> DiscContents {
        let fileManager = FileManager.default
        let entries = ((try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let menu = autorunTarget(in: root)
        var programs: [Program] = []
        var folders: [String] = []
        for entry in entries {
            if BottleMigration.kind(of: entry) == .folder {
                folders.append(entry.lastPathComponent)
            } else if let program = program(entry, menu: menu) {
                programs.append(program)
            }
        }
        if !programs.contains(where: { $0.installer != nil }) {
            for folder in folders where ["setup", "install", "installer"].contains(folder.lowercased()) {
                let inside = (try? fileManager.contentsOfDirectory(at: root.appending(path: folder),
                                                                   includingPropertiesForKeys: nil)) ?? []
                programs += inside.compactMap { program($0, menu: nil) }.filter { $0.installer != nil }
            }
        }
        programs.sort { rank($0) < rank($1) }
        return DiscContents(programs: programs, folders: folders)
    }

    private static func program(_ url: URL, menu: String?) -> Program? {
        guard ["exe", "msi"].contains(url.pathExtension.lowercased()) else { return nil }
        let isMenu = url.lastPathComponent.caseInsensitiveCompare(menu ?? "") == .orderedSame
            || (url.deletingPathExtension().lastPathComponent.lowercased() == "autorun")
        let kind = InstallerKind.detect(url)
        // A disc whose autorun opens the installer directly: it is the installer.
        return Program(url: url, installer: kind, isMenu: isMenu && kind == nil)
    }

    private static func rank(_ program: Program) -> Int {
        if let kind = program.installer { return kind == .other ? 1 : 0 }
        return program.isMenu ? 2 : 3
    }

    /// The program `AUTORUN.INF` opens (`open=AUTORUN.EXE`), as a file name.
    static func autorunTarget(in root: URL) -> String? {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        guard let name = entries.first(where: { $0.lowercased() == "autorun.inf" }),
              let data = try? Data(contentsOf: root.appending(path: name)),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
        else { return nil }
        return parseAutorun(text)
    }

    static func parseAutorun(_ text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].lowercased() == "open" else { continue }
            let command = parts[1]
            // `open="setup\install.exe" /auto`: a quoted program may have spaces; an unquoted one ends at one.
            let program = command.hasPrefix("\"")
                ? String(command.dropFirst().prefix { $0 != "\"" })
                : command.split(separator: " ").first.map(String.init) ?? command
            return program.split(separator: "\\").last.map(String.init)
        }
        return nil
    }
}
