import Foundation

/// Which kind of installer a file is, read from the file itself. Opening an installer leads to the install screen
/// instead of the library: an installer is never shown as a game.
///
/// The kind decides how Plaviox hands it the folder chosen on the install screen, so the installer's own folder
/// page already shows it. Only Inno Setup, NSIS and Windows Installer take a folder from the command line; other
/// installers (InstallShield, Wise, custom ones) show their own default and Plaviox finds the game afterwards.
public enum InstallerKind: String, Sendable, Equatable, Codable {
    case innoSetup, nsis, installShield, windowsInstaller
    /// Called setup or described as an installer, made with something Plaviox doesn't recognise.
    case other

    /// Reads at most this much of a file looking for an installer's signature. The markers sit near the start:
    /// right after the PE image, where the installer's data begins.
    static let scannedBytes = 8 << 20

    public static func detect(_ file: URL) -> InstallerKind? {
        if file.pathExtension.lowercased() == "msi" { return .windowsInstaller }
        guard let info = try? ExecutableInfo.read(file), info.format == .pe32 || info.format == .pe64 else {
            return nil
        }
        let handle = try? FileHandle(forReadingFrom: file)
        let start = (try? handle?.read(upToCount: scannedBytes)) ?? nil
        try? handle?.close()
        return detect(name: file.lastPathComponent, info: info, start: start ?? Data())
    }

    /// - Parameter start: the first bytes of the file.
    static func detect(name: String, info: ExecutableInfo, start: Data) -> InstallerKind? {
        let strings = info.versionStrings.values.joined(separator: "\n").lowercased()
        let manifest = info.manifest?.lowercased() ?? ""
        func has(_ marker: String) -> Bool { start.range(of: Data(marker.utf8)) != nil }

        if strings.contains("inno setup") || has("Inno Setup Setup Data") { return .innoSetup }
        if manifest.contains("nullsoft") || strings.contains("nullsoft") || has("NullsoftInst") { return .nsis }
        if strings.contains("installshield") || has("InstallShield") { return .installShield }

        let lower = name.lowercased()
        let base = (lower as NSString).deletingPathExtension
        let description = (info.versionStrings["FileDescription"] ?? "").lowercased()
        // `unins000.exe` and friends are Inno's and NSIS's uninstallers, not something to install.
        if InstalledPrograms.role(ofFileNamed: lower, description: description) == .uninstaller { return nil }
        if ["setup", "install", "installer", "instal", "inst32"].contains(base) || base.hasPrefix("setup")
            || base.hasSuffix("setup") || base.hasSuffix("installer") || base.hasPrefix("install") {
            return .other
        }
        if ["setup", "installer", "installation", "install"].contains(where: description.contains) { return .other }
        return nil
    }

    /// Arguments that put the installer's folder at `folder` (a Windows path), when this kind takes one.
    public func folderArguments(_ folder: String) -> [String] {
        switch self {
        case .innoSetup: ["/DIR=\(folder)"]
        // NSIS reads `/D=` raw from the command line, only unquoted and last. `wine` quotes an argument with a
        // space in it, but joins the words of one split at its spaces back with plain spaces: unquoted.
        case .nsis: "/D=\(folder)".split(separator: " ").map(String.init)
        // Packages name their main folder differently; a property no package uses is simply ignored.
        case .windowsInstaller: ["INSTALLDIR=\(folder)", "INSTALLFOLDER=\(folder)", "APPLICATIONFOLDER=\(folder)"]
        case .installShield, .other: []
        }
    }

    /// Whether the installer can be told where to install.
    public var takesFolder: Bool { !folderArguments("").isEmpty }
}
