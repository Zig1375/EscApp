import Foundation
@testable import MagicKettleKit
import Testing

@Suite struct RegistryFileTests {
    static let sample = #"""
    WINE REGISTRY Version 2
    ;; All keys relative to REGISTRY\\Machine

    #arch=win64

    [Software\\Studio\\Game] 1792799046
    #time=1dd63486495ac7e
    "Path"="C:\\Games\\Game"
    "Quoted \"name\""=dword:00000001
    "Blob"=hex:01,02,03,\
      04,05
    @="default"

    [Software\\Wine] 1792799059
    #time=6adbf153
    "Version"="win10"

    """#

    @Test func writesBackWhatItRead() {
        let file = RegistryFile(Self.sample)
        #expect(file.text == Self.sample)
        let game = file.key(#"software\\studio\\game"#)
        #expect(game?.values.map(\.name) == [#""Path""#, #""Quoted \"name\"""#, #""Blob""#, "@"])
        #expect(game?.value(#""blob""#) == "\"Blob\"=hex:01,02,03,\\\n  04,05")
    }

    @Test func aRealWineRegistryRoundTrips() throws {
        // Wine's own files, when a runtime is installed for the integration tests.
        guard let home = ProcessInfo.processInfo.environment["MAGICKETTLE_HOME"] else { return }
        let templates = URL(filePath: home).appending(path: "Templates")
        for template in (try? FileManager.default.contentsOfDirectory(atPath: templates.path)) ?? [] {
            for name in BottleMigration.registryFiles {
                let url = templates.appending(path: "\(template)/\(name)")
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                #expect(RegistryFile(text).text == text, "\(template)/\(name)")
            }
        }
    }

    @Test func changesAreNewKeysAndValuesThatDiffer() {
        let base = RegistryFile(Self.sample)
        let changed = RegistryFile(Self.sample
            .replacingOccurrences(of: #""Version"="win10""#, with: #""Version"="win7""#)
            .replacingOccurrences(of: "@=\"default\"\n", with: "")
            + "[Software\\\\New] 1\n#time=1\n\"A\"=\"b\"\n\n")
        let changes = RegistryFile.changes(from: base, to: changed)
        #expect(changes.map(\.path) == [#"Software\\Wine"#, #"Software\\New"#])
        #expect(changes[0].values.map(\.text) == [#""Version"="win7""#])
        // A removed value is not a change to carry.
        #expect(!changes.contains { $0.path == #"Software\\Studio\\Game"# })
    }

    @Test func wineManagedKeysAndTheirSubkeysAreSkipped() {
        let base = RegistryFile("WINE REGISTRY Version 2\n")
        let changed = RegistryFile("""
        WINE REGISTRY Version 2

        [System\\\\ControlSet001\\\\Enum\\\\DISPLAY\\\\APPA050] 1
        "A"="1"

        [System\\\\ControlSet001\\\\EnumOther] 1
        "B"="2"

        """)
        let changes = RegistryFile.changes(from: base, to: changed, skipping: [#"System\ControlSet001\Enum"#])
        #expect(changes.map(\.path) == [#"System\\ControlSet001\\EnumOther"#])
    }

    @Test func applyingReplacesValuesAndAppendsKeys() {
        var file = RegistryFile(Self.sample)
        let changes = RegistryFile.changes(from: RegistryFile("WINE REGISTRY Version 2\n"), to: RegistryFile("""
        WINE REGISTRY Version 2

        [Software\\\\Wine] 5
        "Version"="win7"
        "Extra"="x"

        [Software\\\\New] 5
        #time=5
        "A"="b"

        """))
        file.apply(changes)
        #expect(file.key(#"Software\\Wine"#)?.values.map(\.text) == [#""Version"="win7""#, #""Extra"="x""#])
        #expect(file.text.hasSuffix("[Software\\\\New] 5\n#time=5\n\"A\"=\"b\"\n"))
        // The rewritten file reads back to the same keys.
        #expect(RegistryFile(file.text) == file)
        #expect(file.key(#"Software\\Studio\\Game"#)?.values.count == 4)
    }

    @Test func onlyMissingLeavesExistingValuesAlone() {
        let base = RegistryFile(Self.sample)
        let changed = RegistryFile(Self.sample
            .replacingOccurrences(of: #""Version"="win10""#, with: "\"Version\"=\"win7\"\n\"Added\"=\"1\""))
        let changes = RegistryFile.changes(from: base, to: changed, onlyMissing: true)
        #expect(changes.flatMap(\.values).map(\.text) == [#""Added"="1""#])
    }
}

@Suite struct BottleMigrationTests {
    /// Builds an old template, a game bottle cloned from it that the "game" then changed, and a new template.
    struct Setup {
        let temp: TempFolder
        var oldTemplate: URL { temp.url.appending(path: "old-template") }
        var oldBottle: URL { temp.url.appending(path: "bottle") }
        var newBottle: URL { temp.url.appending(path: "new") }

        init() throws {
            temp = try TempFolder()
            let fileManager = FileManager.default
            let old = temp.url.appending(path: "old-template")
            try write("windows/system32/kernel32.dll", stub("Wine builtin DLL", version: 1), in: old)
            try write("windows/system32/stays.txt", "wine's", in: old)
            try write("windows/themes/light/light.msstyles", "old theme", in: old)
            try write("system.reg", Self.registry(#""Wine"="old""#), in: old, inDrive: false)
            try write(".update-timestamp", "old", in: old, inDrive: false)
            try fileManager.createDirectory(at: old.appending(path: "dosdevices"), withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(atPath: old.appending(path: "dosdevices/c:").path,
                                               withDestinationPath: "../drive_c")

            let bottle = temp.url.appending(path: "bottle")
            try BottleManager.clone(old, to: bottle)
            // What a game and its installer did.
            try write("Program Files/Game/game.exe", "game", in: bottle)
            try write("Program Files/Game/data/level1.pak", "level", in: bottle)
            try write("windows/system32/msvcp140.dll", "vc redist", in: bottle)
            try write("windows/system32/stays.txt", "patched", in: bottle)
            try write("windows/system32/winemetal.dll", stub("Wine builtin DLL", version: 1), in: bottle)
            try write("system.reg", Self.registry(#""Wine"="old""#, game: #""Installed"="1""#), in: bottle,
                      inDrive: false)
            try write(BottleManager.bottleMarker, "{}", in: bottle, inDrive: false)
            try fileManager.createSymbolicLink(atPath: bottle.appending(path: "dosdevices/d:").path,
                                               withDestinationPath: "/Volumes/GAME_CD")

            let new = temp.url.appending(path: "new")
            try write("windows/system32/kernel32.dll", stub("Wine builtin DLL", version: 2), in: new)
            try write("windows/system32/stays.txt", "wine's", in: new)
            try write("windows/themes/aero/aero.msstyles", "new theme", in: new)
            try write("system.reg", Self.registry(#""Wine"="new""#), in: new, inDrive: false)
            try write(".update-timestamp", "new", in: new, inDrive: false)
            try fileManager.createDirectory(at: new.appending(path: "dosdevices"), withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(atPath: new.appending(path: "dosdevices/c:").path,
                                               withDestinationPath: "../drive_c")
        }

        static func registry(_ wine: String, game: String? = nil) -> String {
            var text = "WINE REGISTRY Version 2\n\n[Software\\\\Wine] 1\n\(wine)\n\n"
            if let game { text += "[Software\\\\Studio] 2\n\(game)\n\n" }
            text += "[System\\\\ControlSet001\\\\Enum\\\\PCI] 3\n\"Device\"=\"\(game == nil ? "a" : "b")\"\n\n"
            return text
        }

        func stub(_ mark: String, version: Int) -> Data {
            var data = Data("MZ".utf8) + Data(repeating: 0, count: 0x3E)
            data += Data(mark.utf8) + Data(repeating: UInt8(version), count: 32)
            return data
        }

        func write(_ path: String, _ text: String, in root: URL, inDrive: Bool = true) throws {
            try write(path, Data(text.utf8), in: root, inDrive: inDrive)
        }

        func write(_ path: String, _ data: Data, in root: URL, inDrive: Bool = true) throws {
            let url = root.appending(path: inDrive ? "drive_c/" + path : path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            try data.write(to: url)
        }

        func read(_ path: String) -> String? {
            try? String(contentsOf: newBottle.appending(path: path), encoding: .utf8)
        }
    }

    @Test func carriesWhatTheGameChangedAndNothingOfWines() throws {
        let setup = try Setup()
        let summary = try BottleMigration.carry(from: setup.oldBottle, oldTemplate: setup.oldTemplate,
                                                into: setup.newBottle)

        #expect(setup.read("drive_c/Program Files/Game/game.exe") == "game")
        #expect(setup.read("drive_c/Program Files/Game/data/level1.pak") == "level")
        #expect(setup.read("drive_c/windows/system32/msvcp140.dll") == "vc redist")
        #expect(setup.read("drive_c/windows/system32/stays.txt") == "patched")
        // Wine's own: the new Wine's stays, the old one's doesn't come along.
        let kernel = try Data(contentsOf: setup.newBottle.appending(path: "drive_c/windows/system32/kernel32.dll"))
        #expect(kernel.last == 2)
        #expect(!FileManager.default.fileExists(atPath: setup.newBottle
            .appending(path: "drive_c/windows/system32/winemetal.dll").path))
        #expect(!FileManager.default.fileExists(atPath: setup.newBottle
            .appending(path: "drive_c/windows/themes/light").path))
        #expect(setup.read(".update-timestamp") == "new")
        #expect(setup.read(BottleManager.bottleMarker) == nil)
        // The drive the game's disc was mounted as.
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: setup.newBottle.appending(path: "dosdevices/d:").path) == "/Volumes/GAME_CD")

        let registry = RegistryFile(try #require(setup.read("system.reg")))
        #expect(registry.key(#"Software\\Wine"#)?.value(#""Wine""#) == #""Wine"="new""#)
        #expect(registry.key(#"Software\\Studio"#)?.value(#""Installed""#) == #""Installed"="1""#)
        #expect(registry.key(#"System\\ControlSet001\\Enum\\PCI"#)?.value(#""Device""#) == #""Device"="a""#)
        // game.exe, level1.pak and its folders, msvcp140.dll, stays.txt, d:.
        #expect(summary == BottleMigration.Summary(files: 7, registryValues: 1))
    }

    @Test func withoutTheOldTemplateOnlyWhatsMissingIsCarried() throws {
        let setup = try Setup()
        try BottleMigration.carry(from: setup.oldBottle, oldTemplate: nil, into: setup.newBottle)

        #expect(setup.read("drive_c/Program Files/Game/game.exe") == "game")
        #expect(setup.read("drive_c/windows/system32/msvcp140.dll") == "vc redist")
        // It can't tell the patch from Wine's file any more, so the new Wine's file stays.
        #expect(setup.read("drive_c/windows/system32/stays.txt") == "wine's")
        // Wine's old theme isn't in the new template; it is carried, which is harmless.
        #expect(setup.read("drive_c/windows/themes/light/light.msstyles") == "old theme")
        let registry = RegistryFile(try #require(setup.read("system.reg")))
        #expect(registry.key(#"Software\\Wine"#)?.value(#""Wine""#) == #""Wine"="new""#)
        #expect(registry.key(#"Software\\Studio"#)?.value(#""Installed""#) == #""Installed"="1""#)
    }

    @Test func changingAFileInTheNewBottleLeavesTheOldOneAlone() throws {
        let setup = try Setup()
        try BottleMigration.carry(from: setup.oldBottle, oldTemplate: setup.oldTemplate, into: setup.newBottle)
        try Data("changed".utf8).write(to: setup.newBottle.appending(path: "drive_c/Program Files/Game/game.exe"))
        #expect(try String(contentsOf: setup.oldBottle.appending(path: "drive_c/Program Files/Game/game.exe"),
                           encoding: .utf8) == "game")
    }
}

@Suite struct BottleMoveTests {
    let temp: TempFolder
    let paths: AppPaths

    init() throws {
        temp = try TempFolder()
        paths = AppPaths(root: temp.url, games: temp.url.appending(path: "Games"))
    }

    func runtime(_ id: String) -> RuntimeManifest.Runtime {
        RuntimeManifest.Runtime(id: id, minApp: Version("0.1")!, minMacOS: Version("15")!, components: [])
    }

    /// A template as `ensureTemplate` leaves it, without running Wine.
    func makeTemplate(_ id: String, file: String) throws {
        let template = paths.template(forRuntime: id)
        try FileManager.default.createDirectory(at: template.appending(path: "drive_c/windows"),
                                                withIntermediateDirectories: true)
        try Data(file.utf8).write(to: template.appending(path: "drive_c/windows/wine.txt"))
        try Data("WINE REGISTRY Version 2\n".utf8).write(to: template.appending(path: "user.reg"))
        try JSONEncoder.iso.encode(BottleManager.BottleInfo(runtime: id, createdAt: Date()))
            .write(to: template.appending(path: BottleManager.templateMarker))
    }

    @Test func aBottleOnAnOlderRuntimeMovesAndKeepsTheGamesFiles() async throws {
        try makeTemplate("old", file: "old wine")
        try makeTemplate("new", file: "new wine")
        let bottles = BottleManager(paths: paths)
        let game = GameID.make()
        let other = GameID.make()
        let bottle = try await bottles.ensureBottle(for: game, runtime: runtime("old"), windows: .windows7)
        try await bottles.ensureBottle(for: other, runtime: runtime("old"))
        try FileManager.default.createDirectory(at: bottle.appending(path: "drive_c/Game"),
                                                withIntermediateDirectories: true)
        try Data("installed".utf8).write(to: bottle.appending(path: "drive_c/Game/game.exe"))

        try await bottles.ensureBottle(for: game, runtime: runtime("new"), windows: .windows7)

        #expect(bottles.bottleInfo(for: game)?.runtime == "new")
        #expect(bottles.bottleInfo(for: game)?.movedFrom == "old")
        #expect(try String(contentsOf: bottle.appending(path: "drive_c/Game/game.exe"), encoding: .utf8)
            == "installed")
        #expect(try String(contentsOf: bottle.appending(path: "drive_c/windows/wine.txt"), encoding: .utf8)
            == "new wine")
        #expect(BottleManager.windowsVersion(of: bottle) == .windows7)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.bottles.path)
        #expect(leftovers.sorted() == [game.description, other.description].sorted())
        // The other game still needs the old template for its own move.
        #expect(bottles.hasTemplate(for: runtime("old")))

        try await bottles.ensureBottle(for: other, runtime: runtime("new"))
        #expect(!bottles.hasTemplate(for: runtime("old")))
        #expect(bottles.hasTemplate(for: runtime("new")))
    }

    @Test func aFailedMoveLeavesTheOldBottleAsItWas() async throws {
        try makeTemplate("old", file: "old wine")
        let bottles = BottleManager(paths: paths)
        let game = GameID.make()
        let bottle = try await bottles.ensureBottle(for: game, runtime: runtime("old"))
        try Data("installed".utf8).write(to: bottle.appending(path: "drive_c/game.exe"))

        // The new runtime is neither installed nor has a template.
        await #expect(throws: BottleError.runtimeMissing("new")) {
            try await bottles.ensureBottle(for: game, runtime: runtime("new"))
        }
        #expect(bottles.bottleInfo(for: game)?.runtime == "old")
        #expect(FileManager.default.fileExists(atPath: bottle.appending(path: "drive_c/game.exe").path))
    }
}
