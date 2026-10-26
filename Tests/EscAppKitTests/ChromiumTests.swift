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
        #expect(ChromiumApp.Mode.inProcessGPU.arguments
            == ["--in-process-gpu", "--ignore-gpu-blacklist", "--ignore-gpu-blocklist"])
        #expect(ChromiumApp.Mode.noGPU.arguments.contains("--disable-gpu"))
        #expect(AutoLaunch.nextChromium(after: nil) == .inProcessGPU)
        #expect(AutoLaunch.nextChromium(after: .inProcessGPU) == .noGPU)
        #expect(AutoLaunch.nextChromium(after: .noGPU) == nil)
    }

    @Test func v8KeepsItsFlagsWritableAndTheGamesOwnFlagsStay() throws {
        // "Inquisitor White Prison" (NW.js 0.69, Chromium 106) quit at once without it.
        #expect(ChromiumApp.jsFlags(packageJSON: nil) == "--no-freeze-flags-after-init")
        // RPG Maker MV's package.json.
        let makerMV = Data(#"{"main": "www/index.html", "js-flags": "--expose-gc"}"#.utf8)
        #expect(ChromiumApp.jsFlags(packageJSON: makerMV) == "--expose-gc --no-freeze-flags-after-init")
        let args = Data(#"{"chromium-args": "--force-color-profile=srgb --js-flags=\"--max-old-space-size=4096\""}"#
            .utf8)
        #expect(ChromiumApp.jsFlags(packageJSON: args) == "--max-old-space-size=4096 --no-freeze-flags-after-init")
        #expect(ChromiumApp.jsFlags(packageJSON: Data("not json".utf8)) == "--no-freeze-flags-after-init")

        let temp = try TempFolder()
        try makerMV.write(to: temp.url.appending(path: "package.json"))
        #expect(ChromiumApp.Mode.inProcessGPU.arguments(forProgramIn: temp.url)
            == ChromiumApp.Mode.inProcessGPU.arguments + ["--js-flags=--expose-gc --no-freeze-flags-after-init"])
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
        // Running well past the blank check (0.27 s here), so a busy machine can't end it first.
        let starter = try FakeStarter([.dxvk: Script(windowAt: 0.02, exitAt: 0.8)], logs: logs())
        // The first start's window stays white; the second one draws.
        let picture: @Sendable ([Int32]) async -> WindowLook? = { owners in
            WindowLook(window: 1, blank: owners == [100])
        }
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

@Suite struct LateBlankTests {
    @Test func aWindowAfterTheLauncherThatStaysBlankIsCaught() {
        var late = LateBlank(patience: 40)
        // The launcher's window draws.
        for second in stride(from: 0.0, to: 10, by: 2) {
            let caught = late.observe(WindowLook(window: 1, blank: false), at: second)
            #expect(!caught)
        }
        // The sign-in window that follows stays white.
        var caught = false
        for second in stride(from: 10.0, through: 60, by: 2) where late.observe(WindowLook(window: 2, blank: true),
                                                                               at: second) {
            caught = caught || second >= 50
        }
        #expect(caught)
    }

    @Test func aWindowThatDrewAndThenWentBlackIsTheGamesOwn() {
        var late = LateBlank(patience: 40)
        var caught = late.observe(WindowLook(window: 1, blank: false), at: 0)
        for second in stride(from: 2.0, through: 120, by: 2) {
            caught = caught || late.observe(WindowLook(window: 1, blank: true), at: second)
        }
        #expect(!caught)
    }
}

extension AutoLaunchTests {
    @Test func aBlankWindowAfterAWorkingStartRestartsItDrawnAnotherWay() async throws {
        var chromiumGame = game
        chromiumGame.chromium = .inProcessGPU
        try GameLibrary.modify(paths.library) { $0[chromiumGame.id] = chromiumGame }
        let starter = try FakeStarter([.dxvk: Script(windowAt: 0.02, exitAt: 1.2)], logs: logs())
        let firstLook = Mutex<Date?>(nil)
        // The first start: its launcher window draws, then the window after it stays blank. The second draws.
        let picture: @Sendable ([Int32]) async -> WindowLook? = { owners in
            guard owners == [100] else { return WindowLook(window: 3, blank: false) }
            let since = firstLook.withLock { $0 = $0 ?? Date(); return $0! }
            return Date().timeIntervalSince(since) < 0.15 ? WindowLook(window: 1, blank: false)
                : WindowLook(window: 2, blank: true)
        }
        var fast = timing
        fast.pictureEvery = 0.005
        fast.lateEvery = 0.005
        fast.lateWatch = 0.8
        let result = try await AutoLaunch(paths: paths, starter: starter, windows: starter.windows,
                                          measure: { _ in nil }, picture: picture, timing: fast)
            .play(chromiumGame, runtime: runtime)
        #expect(starter.started.map(\.0) == [.dxvk, .dxvk])
        #expect(result.attempts.first?.failure == .blankPicture)
        #expect(result.working == .dxvk)
        #expect(try GameLibrary.load(from: paths.library)[game.id]?.chromium == .noGPU)
    }
}

@Suite struct LogTextTests {
    @Test func oneForeignByteDoesNotGarbleTheRestOfTheLog() throws {
        let temp = try TempFolder()
        let log = temp.url.appending(path: "run.log")
        var data = Data("[EscApp] Executable /g/異端審問官·白濁監獄.exe\n".utf8)
        // Chromium's "file not found" in code page 1251.
        data.append(contentsOf: [0x5B, 0xCD, 0xE5, 0x20, 0xF3, 0xE4, 0x5D, 0x0A])
        try data.write(to: log)
        let text = try #require(LogDiagnosis.read(log))
        #expect(text.contains("異端審問官·白濁監獄.exe"))
    }
}

extension AutoLaunchTests {
    /// NW.js packed into one exe shows Chromium only by its GPU process; the next attempts follow Chromium's order.
    @Test func chromiumFoundAtRunTimeGoesOnInChromiumsOrder() async throws {
        let starter = try FakeStarter([.dxvk: Script(windowAt: 0.02, exitAt: 0.8),
                                       .wined3d: Script(windowAt: 0.02, exitAt: 0.8)], logs: logs())
        var fast = timing
        fast.pictureEvery = 0.005
        let result = try await AutoLaunch(paths: paths, starter: starter, windows: starter.windows,
                                          measure: { _ in nil }, picture: { _ in WindowLook(window: 1, blank: false) },
                                          gpuProcess: { _ in true }, timing: fast)
            .play(game, runtime: runtime)
        #expect(starter.started.map(\.0) == [.dxvk, .wined3d])
        #expect(result.attempts.first?.failure == .blankPicture)
        #expect(result.working == .wined3d)
        #expect(try GameLibrary.load(from: paths.library)[game.id]?.chromium == .inProcessGPU)
    }

    @Test func chromiumsOrderFollowsWhatWasTried() {
        #expect(AutoLaunch.order(afterFindingChromiumIn: [.dxvk, .wined3d], tried: 0)
                    == [.dxvk, .wined3d, .dxmt, .dxvk])
    }
}

@Suite struct EnigmaVirtualBoxTests {
    /// The box's table: UTF-16 names at odd offsets among binary fields.
    @Test func packedNamesAreReadAtAnyOffset() {
        var table = Data([0x01, 0xFF, 0x00])
        for name in ["%DEFAULT FOLDER%", "icudtl.dat", "libEGL.dll", "en-US.pak", "nw.dll"] {
            table.append(Data(name.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }))
            table.append(contentsOf: [0x00, 0x00, 0x07, 0x9C, 0x01])
        }
        let names = EnigmaVirtualBox.fileNames(in: table)
        #expect(names.isSuperset(of: ["icudtl.dat", "libegl.dll", "en-us.pak", "nw.dll"]))
        #expect(ChromiumApp.isChromium(imports: ["kernel32.dll"], filesBeside: names))
    }

    /// `.enigma1` is 4 KB in memory and 735 MB in the file: the imports in `.enigma2` after it are still found.
    @Test func aSectionSpansItsVirtualSize() {
        let sections = [PEReader.Section(name: ".enigma1", virtualAddress: 0x18F000, virtualSize: 0x1000,
                                         rawOffset: 0x187A00, rawSize: 0x2DDE_F000),
                        PEReader.Section(name: ".enigma2", virtualAddress: 0x190000, virtualSize: 0x45000,
                                         rawOffset: 0x2DF7_6A00, rawSize: 0x45000)]
        #expect(PEReader.offset(of: 0x190010, in: sections) == 0x2DF7_6A10)
        #expect(PEReader.offset(of: 0x18F010, in: sections) == 0x187A10)
    }
}
