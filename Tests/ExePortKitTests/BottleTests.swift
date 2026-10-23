@testable import ExePortKit
import Foundation
import Testing

@Suite struct SharedProfileTests {
    @Test func replacesFoldersWithLinksAndKeepsTheirContents() throws {
        let temp = try TempFolder()
        let user = temp.url.appending(path: "bottle/drive_c/users/zig")
        let profile = temp.url.appending(path: "Profile")
        let startMenu = user.appending(path: "AppData/Roaming/Microsoft/Windows/Start Menu")
        try FileManager.default.createDirectory(at: startMenu, withIntermediateDirectories: true)
        try Data("lnk".utf8).write(to: startMenu.appending(path: "Game.lnk"))
        // A save another bottle already wrote must survive.
        let existingSave = profile.appending(path: "AppData/Roaming/Studio/save.dat")
        try FileManager.default.createDirectory(at: existingSave.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("save".utf8).write(to: existingSave)

        try SharedProfile.link(userFolder: user, to: profile)
        try SharedProfile.link(userFolder: user, to: profile)  // twice is harmless

        for folder in SharedProfile.sharedFolders {
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: user.appending(path: folder).path)
            #expect(link == profile.appending(path: folder).path)
        }
        #expect(FileManager.default.fileExists(
            atPath: profile.appending(path: "AppData/Roaming/Microsoft/Windows/Start Menu/Game.lnk").path))
        #expect(try String(contentsOf: existingSave, encoding: .utf8) == "save")
        // Writing through the link lands in the profile.
        try Data("new".utf8).write(to: user.appending(path: "Saved Games/slot1"))
        #expect(FileManager.default.fileExists(atPath: profile.appending(path: "Saved Games/slot1").path))
    }
}

@Suite struct BottleManagerTests {
    @Test func cloneCopiesTheTemplateAndStaysIndependent() throws {
        let temp = try TempFolder()
        let template = temp.url.appending(path: "template")
        try FileManager.default.createDirectory(at: template.appending(path: "drive_c"),
                                                withIntermediateDirectories: true)
        try Data("REGEDIT".utf8).write(to: template.appending(path: "user.reg"))
        let clone = temp.url.appending(path: "clone")

        try BottleManager.clone(template, to: clone)
        try Data("changed".utf8).write(to: clone.appending(path: "user.reg"))

        #expect(try String(contentsOf: template.appending(path: "user.reg"), encoding: .utf8) == "REGEDIT")
        #expect(FileManager.default.fileExists(atPath: clone.appending(path: "drive_c").path))
    }

    @Test func windowsVersionIsWrittenOnlyWhenItChanges() throws {
        let temp = try TempFolder()
        let userReg = temp.url.appending(path: "user.reg")
        try Data("WINE REGISTRY Version 2\n\n".utf8).write(to: userReg)
        #expect(BottleManager.windowsVersion(of: temp.url) == .windows10)

        try BottleManager.setWindowsVersion(.windows7, bottle: temp.url)
        #expect(BottleManager.windowsVersion(of: temp.url) == .windows7)
        let modified = try FileManager.default.attributesOfItem(atPath: userReg.path)[.modificationDate] as? Date
        try BottleManager.setWindowsVersion(.windows7, bottle: temp.url)
        #expect(try FileManager.default.attributesOfItem(atPath: userReg.path)[.modificationDate] as? Date == modified)
    }

    @Test func aRuntimeWithoutMonoIsRefused() throws {
        let temp = try TempFolder()
        let wine = Wine(root: temp.url)
        #expect(!BottleManager.hasMono(wine))
        try FileManager.default.createDirectory(at: temp.url.appending(path: "share/wine/mono/wine-mono-10.4.1"),
                                                withIntermediateDirectories: true)
        #expect(BottleManager.hasMono(wine))
    }

    @Test func userFolderIgnoresPublic() throws {
        let temp = try TempFolder()
        for name in ["Public", "zig"] {
            try FileManager.default.createDirectory(at: temp.url.appending(path: "drive_c/users/\(name)"),
                                                    withIntermediateDirectories: true)
        }
        #expect(try BottleManager.userFolder(in: temp.url).lastPathComponent == "zig")
    }
}

@Suite struct DiskUsageTests {
    @Test func aCloneCountsOnlyWhatChanged() throws {
        let temp = try TempFolder()
        let paths = AppPaths(root: temp.url, games: temp.url.appending(path: "Games"))
        let template = paths.template(forRuntime: "r1")
        try FileManager.default.createDirectory(at: template.appending(path: "drive_c"),
                                                withIntermediateDirectories: true)
        try Data(repeating: 1, count: 200_000).write(to: template.appending(path: "system.reg"))
        try Data(repeating: 2, count: 100_000).write(to: template.appending(path: "drive_c/big.dll"))

        let bottle = paths.bottle(forGame: .make())
        try FileManager.default.createDirectory(at: paths.bottles, withIntermediateDirectories: true)
        try BottleManager.clone(template, to: bottle)
        try JSONEncoder.iso.encode(BottleManager.BottleInfo(runtime: "r1", createdAt: Date()))
            .write(to: bottle.appending(path: BottleManager.bottleMarker))
        try Data(repeating: 3, count: 50_000).write(to: bottle.appending(path: "drive_c/save.dat"))

        let usage = DiskUsage.measure(paths: paths)
        #expect(usage.bottleCount == 1)
        #expect(usage.templates >= 300_000)
        // The new save and the marker count; the cloned system.reg and big.dll don't.
        #expect(usage.bottles >= 50_000 && usage.bottles < 150_000)
    }
}
