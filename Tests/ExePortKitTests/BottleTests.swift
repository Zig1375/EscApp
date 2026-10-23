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

    @Test func userFolderIgnoresPublic() throws {
        let temp = try TempFolder()
        for name in ["Public", "zig"] {
            try FileManager.default.createDirectory(at: temp.url.appending(path: "drive_c/users/\(name)"),
                                                    withIntermediateDirectories: true)
        }
        #expect(try BottleManager.userFolder(in: temp.url).lastPathComponent == "zig")
    }
}
