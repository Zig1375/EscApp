@testable import EscAppKit
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

@Suite struct WindowsFontsTests {
    @Test func picksTheWindowsFamiliesOnly() {
        let names = ["Arial.ttf", "Arial Unicode.ttf", "Arial Bold Italic.ttf", "Wingdings 2.ttf", "Tahoma.ttf",
                     "Arialic Hollow.ttf", "AppleGothic.ttf", "Impact.otf", "Georgia.ttf"]
        #expect(WindowsFonts.chosen(from: names) == [
            "Arial Bold Italic.ttf", "Arial Unicode.ttf", "Arial.ttf", "Georgia.ttf", "Tahoma.ttf", "Wingdings 2.ttf",
        ])
    }

    @Test func linksFontsAndLeavesAGamesOwnAlone() throws {
        let temp = try TempFolder()
        let fileManager = FileManager.default
        let mac = temp.url.appending(path: "Supplemental")
        let bottle = temp.url.appending(path: "bottle")
        let fonts = bottle.appending(path: "drive_c/windows/Fonts")
        try fileManager.createDirectory(at: mac, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fonts, withIntermediateDirectories: true)
        for name in ["Arial.ttf", "Tahoma.ttf", "Verdana.ttf", "AppleGothic.ttf"] {
            try Data(name.utf8).write(to: mac.appending(path: name))
        }
        // A game's own Tahoma, and a link of EscApp's to a font macOS has since dropped.
        try Data("game".utf8).write(to: fonts.appending(path: "Tahoma.ttf"))
        try fileManager.createSymbolicLink(atPath: fonts.appending(path: "Georgia.ttf").path,
                                           withDestinationPath: mac.appending(path: "Georgia.ttf").path)

        try WindowsFonts.link(bottle: bottle, macFonts: mac)
        try WindowsFonts.link(bottle: bottle, macFonts: mac)  // twice is harmless

        #expect(try fileManager.destinationOfSymbolicLink(atPath: fonts.appending(path: "Arial.ttf").path)
            == mac.appending(path: "Arial.ttf").path)
        #expect(try String(contentsOf: fonts.appending(path: "Verdana.ttf"), encoding: .utf8) == "Verdana.ttf")
        #expect(try String(contentsOf: fonts.appending(path: "Tahoma.ttf"), encoding: .utf8) == "game")
        #expect(try fileManager.contentsOfDirectory(atPath: fonts.path).sorted()
            == ["Arial.ttf", "Tahoma.ttf", "Verdana.ttf"])
    }

    @Test func aFolderThatIsNoBottleIsLeftAlone() throws {
        let temp = try TempFolder()
        try WindowsFonts.link(bottle: temp.url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).isEmpty)
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

@Suite struct TemplateBuildTests {
    /// A finished staging folder: its marker plus a file saying which build made it.
    func staging(_ name: String, in folder: URL) throws -> URL {
        let staging = folder.appending(path: ".staging-r-\(name)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data().write(to: staging.appending(path: BottleManager.templateMarker))
        try Data(name.utf8).write(to: staging.appending(path: "build"))
        return staging
    }

    @Test func buildsFinishingTogetherLeaveOneTemplate() async throws {
        let temp = try TempFolder()
        let destination = temp.url.appending(path: "r")
        let stagings = try (0..<8).map { try staging("\($0)", in: temp.url) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for staging in stagings { group.addTask { try BottleManager.publish(staging, to: destination) } }
            try await group.waitForAll()
        }
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "build").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path) == ["r"])
    }

    @Test func anUnfinishedLeftoverIsReplacedAndAFinishedOneKept() throws {
        let temp = try TempFolder()
        let destination = temp.url.appending(path: "r")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try BottleManager.publish(staging("first", in: temp.url), to: destination)
        try BottleManager.publish(staging("second", in: temp.url), to: destination)
        #expect(try String(contentsOf: destination.appending(path: "build"), encoding: .utf8) == "first")
    }

    @Test func onlyOldStagingFoldersAreRemoved() throws {
        let temp = try TempFolder()
        let old = try staging("old", in: temp.url)
        let fresh = try staging("fresh", in: temp.url)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -7200)],
                                              ofItemAtPath: old.path)
        let template = temp.url.appending(path: "r")
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        BottleManager.removeStaleStaging(in: temp.url)
        let left = try Set(FileManager.default.contentsOfDirectory(atPath: temp.url.path))
        #expect(left == [fresh.lastPathComponent, "r"])
    }
}

@Suite struct GameLibraryLockTests {
    @Test func changesMadeAtTheSameTimeAreAllKept() async throws {
        let temp = try TempFolder()
        let file = temp.url.appending(path: "Games.json")
        let ids = (0..<40).map { _ in GameID.make() }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    try? GameLibrary.modify(file) { library in
                        library[id] = GameRecord(id: id, name: "G", executable: "/g.exe", folder: "/",
                                                 hasMarker: true, addedAt: Date())
                    }
                }
            }
        }
        #expect(try Set(GameLibrary.load(from: file).games.map(\.id)) == Set(ids))
    }
}
