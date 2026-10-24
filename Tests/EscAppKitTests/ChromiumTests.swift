@testable import EscAppKit
import Foundation
import Synchronization
import Testing

@Suite struct ChromiumAppTests {
    @Test func chromiumProgramsAreToldByTheirFiles() {
        // NW.js 0.92 (an RPG Maker MV/MZ Game.exe is a renamed nw.exe).
        #expect(ChromiumApp.isChromium(imports: ["kernel32.dll", "nw_elf.dll"], filesBeside: []))
        // Electron 33: nothing Chromium in its imports, Chromium's files beside it.
        #expect(ChromiumApp.isChromium(imports: ["d3d11.dll", "kernel32.dll"],
                                       filesBeside: ["electron.exe", "icudtl.dat", "resources.pak",
                                                     "chrome_100_percent.pak", "libegl.dll"]))
        // A program linking CEF.
        #expect(ChromiumApp.isChromium(imports: ["libcef.dll"], filesBeside: []))
        // An ordinary game, and one that only ships a .pak of its own.
        #expect(!ChromiumApp.isChromium(imports: ["d3d9.dll"], filesBeside: ["game.exe", "data.pak"]))
    }

    @Test func eachDrawingModeHasItsFallback() {
        #expect(ChromiumApp.Mode.inProcessGPU.arguments == ["--in-process-gpu"])
        #expect(ChromiumApp.Mode.noGPU.arguments.contains("--disable-gpu"))
        #expect(AutoLaunch.nextChromium(after: nil) == .inProcessGPU)
        #expect(AutoLaunch.nextChromium(after: .inProcessGPU) == .noGPU)
        #expect(AutoLaunch.nextChromium(after: .noGPU) == nil)
    }

    @Test func aFlatWindowIsBlankAndAPictureIsNot() {
        let width = 20, height = 20
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        #expect(WindowPicture.isBlank(pixels: pixels, width: width, height: height))
        // A title bar of another colour doesn't count.
        for x in 0..<width { pixels[(1 * width + x) * 4] = 0 }
        #expect(WindowPicture.isBlank(pixels: pixels, width: width, height: height))
        // Anything drawn in the window does.
        pixels[(10 * width + 10) * 4 + 2] = 0
        #expect(!WindowPicture.isBlank(pixels: pixels, width: width, height: height))
    }

    @Test func aWindowCountsAsBlankOnlyForChromiumAndOnlyWhenItNeverShowedAnything() {
        var judge = AttemptJudge(windowTimeout: 60, windowHolds: 10)
        judge.checksPicture = true
        for second in 0..<10 { _ = judge.observe(elapsed: Double(second), window: true, exitCode: nil, idle: false,
                                                  blank: true) }
        // Still blank when the window has held long enough: a cold Chromium start gets more time.
        #expect(judge.observe(elapsed: 10, window: true, exitCode: nil, idle: false) == nil)
        #expect(judge.observe(elapsed: 27, window: true, exitCode: nil, idle: false) == .failed(.blankPicture))

        // Black while it loads, then a picture.
        var loading = AttemptJudge(windowTimeout: 60, windowHolds: 10)
        loading.checksPicture = true
        for second in 0..<9 { _ = loading.observe(elapsed: Double(second), window: true, exitCode: nil, idle: false,
                                                   blank: second < 6) }
        #expect(loading.observe(elapsed: 10, window: true, exitCode: nil, idle: false) == .working)

        // Not Chromium: a long black loading screen is the game's own.
        var other = AttemptJudge(windowTimeout: 60, windowHolds: 10)
        for second in 0..<10 { _ = other.observe(elapsed: Double(second), window: true, exitCode: nil, idle: false,
                                                  blank: true) }
        #expect(other.observe(elapsed: 10, window: true, exitCode: nil, idle: false) == .working)
    }
}

extension AutoLaunchTests {
    @Test func aBlankChromiumWindowIsStartedAgainDrawnAnotherWay() async throws {
        var chromiumGame = game
        chromiumGame.chromium = .inProcessGPU
        try GameLibrary.modify(paths.library) { $0[chromiumGame.id] = chromiumGame }
        let starter = try FakeStarter([.dxvk: .works], logs: logs())
        // The first start's window stays white; the second one draws.
        let picture: @Sendable ([Int32]) async -> Bool? = { owners in owners == [100] }
        var fast = timing
        fast.pictureEvery = 0.005
        let result = try await AutoLaunch(paths: paths, starter: starter, windows: starter.windows,
                                          measure: { _ in nil }, picture: picture, timing: fast)
            .play(chromiumGame, runtime: runtime)
        #expect(starter.started.map(\.0) == [.dxvk, .dxvk])
        #expect(result.attempts.first?.failure == .blankPicture)
        #expect(result.working == .dxvk)
        #expect(try GameLibrary.load(from: paths.library)[game.id]?.chromium == .noGPU)
    }
}

@Suite struct StoreClientProgramTests {
    @Test func aStoreInstalledByItsOwnInstallerIsKnownByItsClient() throws {
        let bottle = FileManager.default.temporaryDirectory.appending(path: "store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bottle) }
        let steam = bottle.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")
        try FileManager.default.createDirectory(at: steam.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: steam)
        #expect(Store.clientProgram(steam, in: bottle) == .steam)
        #expect(Store.clientProgram(bottle.appending(path: "drive_c/Games/game.exe"), in: bottle) == nil)
    }
}

extension ChromiumAppTests {
    /// Electron 33 imports d3d12.dll for WebGPU but draws with Direct3D 11: it isn't a DirectX 12 game.
    @Test func chromiumsDirectX12ImportDoesNotMakeItADirectX12Game() {
        var info = ExecutableInfo(format: .pe64, imports: ["d3d11.dll", "d3d12.dll"], productName: nil, icon: nil,
                                  dpiAware: false)
        #expect(info.directX.contains(.d3d12))
        info.chromium = true
        #expect(info.directX == [.d3d11])
    }
}
