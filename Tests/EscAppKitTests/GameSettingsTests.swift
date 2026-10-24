@testable import EscAppKit
import Foundation
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
