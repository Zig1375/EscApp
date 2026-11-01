import Foundation
@testable import MagicKettleKit
import Testing

@Suite struct GameSettingsTests {
    func game() -> GameRecord {
        GameRecord(id: .make(), name: "Heroes", executable: "/Games/Heroes/heroes3.exe", folder: "/Games/Heroes",
                   hasMarker: true, addedAt: Date())
    }

    @Test func environmentLinesAndTheFrameCounter() {
        var record = game()
        record.environment = "#  one variable per line: NAME=value\nDXVK_HUD=fps\n\n  WINEDEBUG = +relay\nnot a line\n"
        record.fpsCounter = true
        let environment = GameSettings.environment(of: record)
        #expect(environment == ["DXVK_HUD": "fps", "WINEDEBUG": " +relay", "MTL_HUD_ENABLED": "1"])
        // The player's own value wins over the counter's.
        record.environment = "MTL_HUD_ENABLED=0"
        #expect(GameSettings.environment(of: record)["MTL_HUD_ENABLED"] == "0")
    }

    @Test func launchParametersKeepQuotedValuesWhole() {
        #expect(GameSettings.arguments("-windowed  -mod \"My Mod\" \"\"") == ["-windowed", "-mod", "My Mod", ""])
        #expect(GameSettings.arguments("   ").isEmpty)
    }

    @Test func retinaFollowsTheGameUnlessChosen() {
        #expect(GameSettings.retina(nil, dpiAware: true))
        #expect(!GameSettings.retina(.auto, dpiAware: false))
        #expect(GameSettings.retina(.on, dpiAware: false))
        #expect(!GameSettings.retina(.off, dpiAware: true))
    }

    @Test func sharedSettingsSurviveASaveAndDefaultWithoutAFile() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "magickettle-settings-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(SharedSettings.load(from: file) == SharedSettings())
        try SharedSettings(newGameRetina: .off).save(to: file)
        #expect(SharedSettings.load(from: file).newGameRetina == .off)
    }

    @Test func autoSaysWhichBackendAndWhy() {
        let ddraw = ExecutableInfo(format: .pe32, imports: ["ddraw.dll"], productName: nil, icon: nil,
                                   dpiAware: false)
        var record = game()
        #expect(GameSettings.autoBackend(for: record, info: ddraw)?.1 == .directDraw)
        record.backend = .dxvk
        #expect(GameSettings.autoBackend(for: record, info: ddraw)! == (.dxvk, .workedBefore))
        let win16 = ExecutableInfo(format: .win16, imports: [], productName: nil, icon: nil, dpiAware: false)
        #expect(GameSettings.autoBackend(for: record, info: win16) == nil)
    }

    @Test func autoScalingSaysWhatItDoes() {
        let screen = GameScaling.Size(width: 1728, height: 1056)
        var record = game()
        #expect(GameSettings.autoScaling(for: record, retina: false, screen: screen) == .notSeenYet)
        #expect(GameSettings.autoScaling(for: record, retina: true, screen: screen) == .drawsForRetina)
        record.window = GameScaling.LearnedWindow(width: 800, height: 600, fullScreen: true)
        #expect(GameSettings.autoScaling(for: record, retina: false, screen: screen) == .fullScreen)
        record.window = GameScaling.LearnedWindow(width: 640, height: 480, fullScreen: false)
        #expect(GameSettings.autoScaling(for: record, retina: false, screen: screen)
            == .enlarged(width: 640, height: 480, scale: 2))
        record.window = GameScaling.LearnedWindow(width: 1280, height: 800, fullScreen: false)
        #expect(GameSettings.autoScaling(for: record, retina: false, screen: screen)
            == .largeEnough(width: 1280, height: 800))
    }

    @Test func aGameInsideItsWindowsCantBeReset() {
        let paths = AppPaths(root: URL(filePath: "/E"), games: URL(filePath: "/G"))
        var record = game()
        #expect(GameSettings.canReset(record, paths: paths))
        record.executable = paths.bottle(forGame: record.id).appending(path: "drive_c/Program Files/H/h.exe").path
        #expect(!GameSettings.canReset(record, paths: paths))
    }
}

/// What a launch writes into the bottle (`GameLauncher.configure`), on a bottle of two registry files.
@Suite struct LaunchConfigurationTests {
    let temp: TempFolder
    var bottle: URL { temp.url }
    let screen = GameScaling.Size(width: 1728, height: 1056)

    init() throws {
        temp = try TempFolder()
        for file in ["user.reg", "system.reg"] {
            try Data("WINE REGISTRY Version 2\n\n".utf8).write(to: temp.url.appending(path: file))
        }
    }

    func game() -> GameRecord {
        GameRecord(id: .make(), name: "G", executable: "/g.exe", folder: "/", hasMarker: true, addedAt: Date())
    }

    func userReg() throws -> String { try String(contentsOf: bottle.appending(path: "user.reg"), encoding: .utf8) }

    func value(_ key: String, _ name: String) throws -> String? {
        WineRegistry.string(in: try userReg(), key: key, name: name)
    }

    @Test func aPlainGameGetsTheDefaults() throws {
        let scale = try GameLauncher.configure(bottle: bottle, for: game(), retina: false, screen: screen)
        #expect(scale == 1)
        #expect(try value(#"Software\Wine\Mac Driver"#, "RetinaMode") == "n")
        #expect(try value(#"Software\Wine\Mac Driver"#, "LeftCommandIsCtrl") == "y")
        #expect(try value(#"Software\Wine\Mac Driver"#, "RightCommandIsCtrl") == "y")
        #expect(try value(#"Software\Wine\X11 Driver"#, "EmulateModeset") == "y")
        #expect(try value(#"Software\Wine\X11 Driver"#, "StretchWindows") == "y")
        #expect(try userReg().contains(#""ShowCrashDialog"=dword:00000000"#))
        #expect(try userReg().contains(#""LogPixels"=dword:00000060"#))
    }

    @Test func settingsAndTheLearnedWindowReachTheBottle() throws {
        var record = game()
        record.commandAsControl = false
        record.window = GameScaling.LearnedWindow(width: 640, height: 480, fullScreen: false)
        let scale = try GameLauncher.configure(bottle: bottle, for: record, retina: false, screen: screen)
        #expect(scale == 2)
        #expect(try userReg().contains(#""LogPixels"=dword:000000c0"#))
        #expect(try value(#"Software\Wine\Mac Driver"#, "RightCommandIsCtrl") == "n")

        // Retina on: the game draws for it, nothing is enlarged.
        #expect(try GameLauncher.configure(bottle: bottle, for: record, retina: true, screen: screen) == 1)
        #expect(try value(#"Software\Wine\Mac Driver"#, "RetinaMode") == "y")
        #expect(try userReg().contains(#""LogPixels"=dword:00000060"#))
    }

    @Test func anUnchangedBottleIsntRewritten() throws {
        let record = game()
        _ = try GameLauncher.configure(bottle: bottle, for: record, retina: true, screen: screen)
        let file = bottle.appending(path: "user.reg")
        let before = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = try GameLauncher.configure(bottle: bottle, for: record, retina: true, screen: screen)
        #expect(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == before)
    }
}
