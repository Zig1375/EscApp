import Foundation
@testable import MagicKettleKit
import Testing

private let fixtures = URL(filePath: #filePath).deletingLastPathComponent()
    .appending(path: "../Fixtures").standardizedFileURL

@Suite struct WindowsPathTests {
    @Test func aMacFolderUnderTheGamesDriveGetsItsWindowsPath() {
        let games = URL(filePath: "/tmp/x/Games", directoryHint: .isDirectory)
        let folder = games.appending(path: "Probe Game", directoryHint: .isDirectory)
        #expect(WindowsPath.windowsPath(of: folder, under: folder.deletingLastPathComponent(), drive: "g")
            == #"G:\Probe Game"#)
        #expect(WindowsPath.windowsPath(of: games, under: games, drive: "g") == #"G:\"#)
        #expect(WindowsPath.windowsPath(of: URL(filePath: "/elsewhere"), under: games, drive: "g") == nil)
    }

    @Test func aFolderNotMadeYetUnderAnExistingOneStillMatches() throws {
        // Under /private/var or /private/tmp, an existing folder and a new one inside it used to look unrelated.
        let temp = try TempFolder()
        // The temporary folder is /var/folders/…, which is /private/var/folders/… spelt out.
        let root = URL(filePath: "/private" + temp.url.path(percentEncoded: false), directoryHint: .isDirectory)
        let folder = root.appending(path: "Probe Game", directoryHint: .isDirectory)
        #expect(WindowsPath.windowsPath(of: folder, under: root, drive: "g") == #"G:\Probe Game"#)
    }

    @Test func aWindowsPathResolvesThroughTheBottlesDrivesWithoutCase() throws {
        let temp = try TempFolder()
        let bottle = temp.url.appending(path: "bottle")
        let games = temp.url.appending(path: "Games/Probe Game")
        try FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
        try Data().write(to: games.appending(path: "ProbeGame.exe"))
        try FileManager.default.createDirectory(at: bottle.appending(path: "dosdevices"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bottle.appending(path: "dosdevices/g:").path,
                                                   withDestinationPath: temp.url.appending(path: "Games").path)
        let url = WindowsPath.macURL(for: #"G:\PROBE GAME\probegame.exe"#, bottle: bottle)
        #expect(url?.lastPathComponent == "ProbeGame.exe")
        #expect(url?.deletingLastPathComponent().lastPathComponent == "Probe Game")
        #expect(WindowsPath.macURL(for: #"Q:\x.exe"#, bottle: bottle) == nil)
    }
}

@Suite struct ShellLinkTests {
    @Test func readsTheTargetOfAShortcutWineMade() throws {
        let link = fixtures.appending(path: "shortcuts/wine-probe-game.lnk")
        #expect(ShellLink.target(of: link) == #"G:\Probe Game\probegame.exe"#)
    }

    @Test func somethingElseHasNoTarget() {
        #expect(ShellLink.target(in: Data("not a shortcut".utf8)) == nil)
        #expect(ShellLink.target(in: Data()) == nil)
    }
}

@Suite struct InstallerKindTests {
    func info(_ strings: [String: String] = [:], manifest: String? = nil) -> ExecutableInfo {
        var info = ExecutableInfo(format: .pe32, imports: [], productName: nil, icon: nil, dpiAware: false)
        info.versionStrings = strings
        info.manifest = manifest
        return info
    }

    @Test func recognisesInstallersByWhatTheyCarry() {
        let innoData = Data("..Inno Setup Setup Data (5.5.9)".utf8)
        #expect(InstallerKind.detect(name: "game.exe", info: info(), start: innoData) == .innoSetup)
        let innoComment = info(["Comments": "This installation was built with Inno Setup."])
        #expect(InstallerKind.detect(name: "x.exe", info: innoComment, start: Data()) == .innoSetup)
        let nsis = info(manifest: #"<assemblyIdentity name="Nullsoft.NSIS.exehead"/>"#)
        #expect(InstallerKind.detect(name: "x.exe", info: nsis, start: Data()) == .nsis)
        #expect(InstallerKind.detect(name: "x.exe", info: info(["CompanyName": "InstallShield Software Corporation"]),
                                     start: Data()) == .installShield)
    }

    @Test func otherInstallersByNameOrDescription() {
        #expect(InstallerKind.detect(name: "SETUP.EXE", info: info(), start: Data()) == .other)
        #expect(InstallerKind.detect(name: "Fallout2Setup.exe", info: info(), start: Data()) == .other)
        #expect(InstallerKind.detect(name: "x.exe", info: info(["FileDescription": "Game Installer"]), start: Data())
            == .other)
        #expect(InstallerKind.detect(name: "fallout2.exe", info: info(), start: Data()) == nil)
        // An uninstaller made by an installer is not one.
        #expect(InstallerKind.detect(name: "unins000.exe", info: info(), start: Data()) == nil)
    }

    @Test func theSetupProbeIsInnoAndMsiIsWindowsInstaller() {
        #expect(InstallerKind.detect(fixtures.appending(path: "probes/setup-x86.exe")) == .innoSetup)
        #expect(InstallerKind.detect(URL(filePath: "/tmp/game.MSI")) == .windowsInstaller)
        #expect(InstallerKind.detect(fixtures.appending(path: "probes/d3d9-x86.exe")) == nil)
    }

    @Test func eachKindGetsTheFolderItUnderstands() {
        #expect(InstallerKind.innoSetup.folderArguments(#"G:\Game"#) == [#"/DIR=G:\Game"#])
        #expect(InstallerKind.nsis.folderArguments(#"G:\Game"#) == [#"/D=G:\Game"#])
        #expect(InstallerKind.nsis.folderArguments(#"G:\Fallout 2"#) == [#"/D=G:\Fallout"#, "2"])
        #expect(InstallerKind.windowsInstaller.folderArguments("G:").contains("INSTALLDIR=G:"))
        #expect(!InstallerKind.installShield.takesFolder && !InstallerKind.other.takesFolder)
    }
}

@Suite struct InstalledProgramsTests {
    @Test func rolesFromNames() {
        #expect(InstalledPrograms.role(ofFileNamed: "unins000.exe") == .uninstaller)
        #expect(InstalledPrograms.role(ofFileNamed: "Uninstall.exe") == .uninstaller)
        #expect(InstalledPrograms.role(ofFileNamed: "f2_res_config.exe") == .settings)
        #expect(InstalledPrograms.role(ofFileNamed: "vcredist_x86.exe") == .redistributable)
        #expect(InstalledPrograms.role(ofFileNamed: "dxsetup.exe", path: "/Game/DirectX") == .redistributable)
        #expect(InstalledPrograms.role(ofFileNamed: "fallout2.exe") == .game)
    }

    @Test func theShortcutsTargetIsRecommendedAndTheUninstallerLeftOut() throws {
        let temp = try TempFolder()
        let folder = temp.url.appending(path: "Probe Game")
        let probes = fixtures.appending(path: "probes")
        try FileManager.default.createDirectory(at: folder.appending(path: "Redist"),
                                                withIntermediateDirectories: true)
        // The settings tool is the bigger file: size alone would pick it.
        try FileManager.default.copyItem(at: probes.appending(path: "d3d9-x86.exe"),
                                         to: folder.appending(path: "run.exe"))
        try FileManager.default.copyItem(at: probes.appending(path: "d3d11-x64.exe"),
                                         to: folder.appending(path: "big.exe"))
        try FileManager.default.copyItem(at: probes.appending(path: "d3d11-x86.exe"),
                                         to: folder.appending(path: "game_config.exe"))
        try FileManager.default.copyItem(at: probes.appending(path: "setup-x86.exe"),
                                         to: folder.appending(path: "unins000.exe"))
        try FileManager.default.copyItem(at: probes.appending(path: "d3d9-x86.exe"),
                                         to: folder.appending(path: "Redist/vcredist_x86.exe"))

        let found = InstalledPrograms.find(in: [folder], shortcutTargets: [folder.appending(path: "run.exe")],
                                           name: "Probe Game")
        #expect(found.programs.map(\.name) == ["run.exe", "big.exe", "game_config.exe"])
        #expect(found.recommended?.name == "run.exe")
        #expect(found.programs.last?.role == .settings)
        #expect(found.uninstaller == "unins000.exe")

        let unnamed = InstalledPrograms.find(in: [folder], shortcutTargets: [], name: "Big")
        #expect(unnamed.recommended?.name == "big.exe")
    }

    @Test func newFoldersAreWhatTheTemplateLacks() throws {
        let temp = try TempFolder()
        let template = temp.url.appending(path: "template")
        let bottle = temp.url.appending(path: "bottle")
        for root in [template, bottle] {
            try FileManager.default.createDirectory(at: root.appending(path: "drive_c/Program Files/Common Files"),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appending(path: "drive_c/windows"),
                                                    withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: bottle.appending(path: "drive_c/Program Files/Probe Game"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bottle.appending(path: "drive_c/GAMES"),
                                                withIntermediateDirectories: true)
        let names = InstalledPrograms.newFolders(in: bottle, template: template).map(\.lastPathComponent)
        #expect(Set(names) == ["Probe Game", "GAMES"])
    }
}

@Suite struct DiscTests {
    @Test func readsHdiutilsAnswers() throws {
        let attach = """
        hdiutil: WARNING: 'hdiutil attach' is deprecated.
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>system-entities</key><array>
        <dict><key>dev-entry</key><string>/dev/disk14</string><key>mount-point</key><string>/tmp/mnt</string></dict>
        </array></dict></plist>
        """
        let parsed = DiscImage.parseAttach(DiscImage.plist(in: attach))
        #expect(parsed?.device == "/dev/disk14")
        #expect(parsed?.mountPoint == "/tmp/mnt")

        let info = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>images</key><array>
        <dict><key>image-path</key><string>/Games/Fallout2.iso</string><key>system-entities</key><array>
        <dict><key>dev-entry</key><string>/dev/disk15s1</string>
        <key>mount-point</key><string>/Volumes/FALLOUT2</string></dict>
        <dict><key>dev-entry</key><string>/dev/disk15</string></dict></array></dict>
        <dict><key>image-path</key><string>/no/volume.dmg</string><key>system-entities</key><array>
        <dict><key>dev-entry</key><string>/dev/disk16</string></dict></array></dict>
        </array></dict></plist>
        """
        let discs = DiscImage.parseInfo(DiscImage.plist(in: info))
        #expect(discs == [MountedDisc(image: URL(filePath: "/Games/Fallout2.iso"),
                                      mountPoint: URL(filePath: "/Volumes/FALLOUT2"), device: "/dev/disk15",
                                      attachedByMagicKettle: false)])
    }

    @Test func insertingPutsTheDiscAndItsDeviceInDriveD() throws {
        let temp = try TempFolder()
        let bottle = temp.url
        try FileManager.default.createDirectory(at: bottle.appending(path: "dosdevices"),
                                                withIntermediateDirectories: true)
        try Data("WINE REGISTRY Version 2\n".utf8).write(to: bottle.appending(path: "system.reg"))
        let disc = MountedDisc(image: URL(filePath: "/g.iso"), mountPoint: URL(filePath: "/tmp/mnt"),
                               device: "/dev/disk14", attachedByMagicKettle: true)
        try DiscDrive.insert(disc, into: bottle)
        try DiscDrive.insert(disc, into: bottle)
        let devices = bottle.appending(path: "dosdevices")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: devices.appending(path: "d:").path)
            == "/tmp/mnt")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: devices.appending(path: "d::").path)
            == "/dev/rdisk14")
        let registry = try String(contentsOf: bottle.appending(path: "system.reg"), encoding: .utf8)
        #expect(WineRegistry.string(in: registry, key: #"Software\Wine\Drives"#, name: "d:") == "cdrom")

        DiscDrive.eject(from: bottle)
        #expect(BottleMigration.kind(of: devices.appending(path: "d:")) == nil)
    }

    @Test func theDiscMenuAndInstallerAreToldApart() throws {
        let temp = try TempFolder()
        let probes = fixtures.appending(path: "probes")
        try FileManager.default.copyItem(at: probes.appending(path: "setup-x86.exe"),
                                         to: temp.url.appending(path: "SETUP.EXE"))
        try FileManager.default.copyItem(at: probes.appending(path: "d3d9-x86.exe"),
                                         to: temp.url.appending(path: "AUTORUN.EXE"))
        try Data("[autorun]\r\nopen=AUTORUN.EXE\r\nicon=game.ico\r\n".utf8)
            .write(to: temp.url.appending(path: "AUTORUN.INF"))
        for folder in ["MANUAL", "DATA"] {
            try FileManager.default.createDirectory(at: temp.url.appending(path: folder),
                                                    withIntermediateDirectories: true)
        }
        let contents = DiscContents.read(temp.url)
        #expect(contents.programs.map(\.name) == ["SETUP.EXE", "AUTORUN.EXE"])
        #expect(contents.installer?.installer == .innoSetup)
        #expect(contents.programs.last?.isMenu == true)
        #expect(contents.folders == ["DATA", "MANUAL"])
        #expect(DiscContents.parseAutorun(#"open="setup\install.exe" /auto"#) == "install.exe")
    }
}

@Suite struct GameInstallerTests {
    @Test func namesComeFromTheInstallerOrTheDisc() {
        let probes = fixtures.appending(path: "probes")
        #expect(GameInstaller.suggestedName(installer: probes.appending(path: "setup-x86.exe")) == "Probe Game")
        #expect(GameInstaller.suggestedName(installer: URL(filePath: "/Volumes/X/SETUP.EXE"),
                                            disc: URL(filePath: "/Games/Fallout2.iso")) == "Fallout2")
        #expect(GameInstaller.suggestedName(installer: URL(filePath: "/Downloads/inst/Probe MSI Game.msi"))
            == "Probe MSI Game")
        #expect(GameInstaller.suggestedName(installer: URL(filePath: "/Downloads/Fallout 2/setup.msi")) == "Fallout 2")
    }

    @Test func theDefaultFolderIsUnderGamesWithASafeName() {
        let paths = AppPaths(root: URL(filePath: "/tmp/e"), games: URL(filePath: "/Users/me/Games"))
        let installer = GameInstaller(paths: paths)
        #expect(installer.defaultFolder(for: "Fallout 2").path(percentEncoded: false) == "/Users/me/Games/Fallout 2/")
        #expect(installer.defaultFolder(for: "Two  Spaces ").lastPathComponent == "Two Spaces")
        #expect(installer.defaultFolder(for: "Half-Life: Opposing Force?").lastPathComponent
            == "Half-Life- Opposing Force-")
    }

    @Test func aPackageGetsItsFolderAsTheWholeDrive() {
        let folder = URL(filePath: "/Games/Probe MSI", directoryHint: .isDirectory)
        let package = GameInstaller.Plan(installer: URL(filePath: "/x/p.msi"), kind: .windowsInstaller, name: "P",
                                         folder: folder)
        let root = GameInstaller.gamesDriveRoot(for: package)
        #expect(root == folder)
        #expect(WindowsPath.windowsPath(of: folder, under: root, drive: "g") == #"G:\"#)
        var setup = package
        setup.kind = .innoSetup
        #expect(GameInstaller.gamesDriveRoot(for: setup).path(percentEncoded: false) == "/Games/")
    }

    @Test func eachKindIsStartedTheWayItTakesItsFolder() {
        let paths = AppPaths(root: URL(filePath: "/tmp/e"), games: URL(filePath: "/G"))
        let installer = GameInstaller(paths: paths)
        let disc = MountedDisc(image: URL(filePath: "/g.iso"), mountPoint: URL(filePath: "/tmp/mnt"),
                               device: "/dev/disk14", attachedByMagicKettle: true)
        func plan(_ kind: InstallerKind, onDisc: Bool = true) -> GameInstaller.Plan {
            GameInstaller.Plan(installer: URL(filePath: onDisc ? "/tmp/mnt/SETUP/SETUP.EXE" : "/x/setup.exe"),
                               kind: kind, name: "G", folder: URL(filePath: "/G/G"), disc: onDisc ? disc : nil)
        }
        let bottle = URL(filePath: "/b")
        #expect(installer.command(for: plan(.innoSetup), folder: #"G:\G"#, bottle: bottle)
            == [#"D:\SETUP\SETUP.EXE"#, #"/DIR=G:\G"#])
        #expect(installer.command(for: plan(.other, onDisc: false), folder: #"G:\G"#, bottle: bottle)
            == ["/x/setup.exe"])
        #expect(installer.command(for: plan(.windowsInstaller), folder: #"G:\G"#, bottle: bottle).prefix(3)
            == ["msiexec", "/i", #"D:\SETUP\SETUP.EXE"#])
        #expect(installer.command(for: plan(.nsis), folder: #"G:\Probe Game"#, bottle: bottle)
            == [#"D:\SETUP\SETUP.EXE"#, #"/D=G:\Probe"#, "Game"])
    }
}
