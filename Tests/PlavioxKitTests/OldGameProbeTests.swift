import CoreGraphics
import Foundation
@testable import PlavioxKit
import Synchronization
import Testing

// Installing, discs, enlarging and moving bottles on real Wine, with the probes in Tests/Fixtures. Same opt-in as
// `ProbeLaunchTests`: `PLAVIOX_INTEGRATION=1` and an `PLAVIOX_HOME` whose runtime is installed. Windows and the
// probes' message boxes open for a few seconds each.

/// The scratch home's paths and current runtime.
enum WineHome {
    static func current() throws -> (AppPaths, RuntimeManifest.Runtime) {
        let paths = AppPaths.standard()
        let runtime = try #require(RuntimeCatalog(
            installed: RuntimeInstaller(paths: paths).installedRuntimes(), manifest: RuntimeManifest.bundled(),
            app: Version("0.1")!, macOS: Version("15")!).current, "No runtime installed in PLAVIOX_HOME")
        return (paths, runtime)
    }

    /// A game disc: the setup probe as SETUP.EXE and the game in GAME\, labelled PROBEGAME like the CD probe wants.
    static func makeDisc(in folder: URL) async throws -> URL {
        let root = folder.appending(path: "disc")
        try FileManager.default.createDirectory(at: root.appending(path: "GAME"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Probes.url("setup-x86"), to: root.appending(path: "SETUP.EXE"))
        try FileManager.default.copyItem(at: Probes.url("d3d9-x86"), to: root.appending(path: "GAME/probegame.exe"))
        try FileManager.default.copyItem(at: Probes.url("d3d11-x86"),
                                         to: root.appending(path: "GAME/probe_config.exe"))
        let iso = folder.appending(path: "Probe Game.iso")
        try await ProcessRunner.check("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-default-volume-name",
                                                           "PROBEGAME", "-o", iso.path, root.path])
        return iso
    }

    static func gameFolder(_ name: String, paths: AppPaths) -> URL {
        paths.games.appending(path: "\(name)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["PLAVIOX_INTEGRATION"] == "1"), .serialized)
struct InstallProbeTests {
    @Test func aGameInstallsFromItsDiscAndPlaysWithIt() async throws {
        let (paths, runtime) = try WineHome.current()
        let temp = try TempFolder()
        let disc = try await DiscImage.attach(try await WineHome.makeDisc(in: temp.url), paths: paths)
        let folder = WineHome.gameFolder("Probe Game", paths: paths)
        defer { try? FileManager.default.removeItem(at: folder) }
        let installer = disc.mountPoint.appending(path: "SETUP.EXE")
        #expect(InstallerKind.detect(installer) == .innoSetup)

        let gameInstaller = GameInstaller(paths: paths)
        let plan = GameInstaller.Plan(installer: installer, kind: .innoSetup, name: "Probe Game", folder: folder,
                                      disc: disc)
        let installed = try await gameInstaller.install(plan, runtime: runtime)
        defer { try? GameRemover.removeFromApp(installed.id, paths: paths) }
        // Inno's /DIR= reached it, and its Start menu shortcut names the game.
        #expect(installed.found.recommended?.url.standardizedFileURL
            == folder.appending(path: "probegame.exe").standardizedFileURL)
        #expect(installed.found.recommended?.hasShortcut == true)
        #expect(installed.found.uninstaller == "unins000.exe")
        let record = try gameInstaller.finish(installed, program: #require(installed.found.recommended).url,
                                              keepDisc: true)
        await DiscImage.detach(disc)
        #expect(record.disc != nil)

        let result = try await AutoLaunch(paths: paths).play(record, runtime: runtime)
        #expect(result.working != nil)
        // The disc went into D: for the game and back out after it.
        let attached = try await DiscImage.attached().map(\.image.lastPathComponent)
        #expect(!attached.contains("Probe Game.iso"))
    }

    @Test func aWindowsInstallerPackageGetsTheFolder() async throws {
        let (paths, runtime) = try WineHome.current()
        let package = Probes.folder.appending(path: "../installers/probe-game.msi").standardizedFileURL
        let folder = WineHome.gameFolder("Probe MSI", paths: paths)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plan = GameInstaller.Plan(installer: package, kind: .windowsInstaller, name: "Probe MSI", folder: folder)
        let installed = try await GameInstaller(paths: paths).install(plan, runtime: runtime)
        defer { try? GameRemover.removeFromApp(installed.id, paths: paths) }
        #expect(installed.found.recommended?.url.standardizedFileURL
            == folder.appending(path: "probegame.exe").standardizedFileURL)
    }

    @Test func nsisGetsItsFolderUnquoted() async throws {
        let (paths, runtime) = try WineHome.current()
        let temp = try TempFolder()
        let source = temp.url.appending(path: "Probe NSIS")
        try FileManager.default.createDirectory(at: source.appending(path: "GAME"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Probes.url("nsis-x86"), to: source.appending(path: "setup.exe"))
        try FileManager.default.copyItem(at: Probes.url("d3d9-x86"), to: source.appending(path: "GAME/probegame.exe"))
        try FileManager.default.copyItem(at: Probes.url("d3d11-x86"),
                                         to: source.appending(path: "GAME/probe_config.exe"))
        // A space in the folder: NSIS only takes it when `/D=` arrives unquoted.
        let folder = WineHome.gameFolder("NSIS Game", paths: paths)
        defer { try? FileManager.default.removeItem(at: folder) }
        let setup = source.appending(path: "setup.exe")
        #expect(InstallerKind.detect(setup) == .nsis)
        let plan = GameInstaller.Plan(installer: setup, kind: .nsis, name: "NSIS Game", folder: folder)
        let installed = try await GameInstaller(paths: paths).install(plan, runtime: runtime)
        defer { try? GameRemover.removeFromApp(installed.id, paths: paths) }
        #expect(installed.found.programs.map(\.name) == ["probegame.exe", "probe_config.exe"])
        #expect(installed.found.programs.last?.role == .settings)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["PLAVIOX_INTEGRATION"] == "1"), .serialized)
struct DiscProbeTests {
    @Test func aGameAsksForItsCDAndRunsFromABinCue() async throws {
        let (paths, runtime) = try WineHome.current()
        let temp = try TempFolder()
        let exe = temp.url.appending(path: "Game/cdgame.exe")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Probes.url("cd-x86"), to: exe)
        var game = try GameIdentifier(paths: paths).identify(executable: exe).record
        defer { try? GameRemover.removeFromApp(game.id, paths: paths) }

        // Without its disc: the request is caught while the box is up, and nothing is retried.
        let asked = Mutex<String?>(nil)
        let without = try await AutoLaunch(paths: paths).play(game, runtime: runtime) { event in
            if case let .asksForDisc(text) = event { asked.withLock { $0 = text } }
        }
        #expect(asked.withLock { $0 }?.contains("Please insert the Probe Game CD") == true)
        #expect(without.attempts.count == 1)
        #expect(without.working == nil)

        // With a BIN/CUE of its disc.
        let iso = try Data(contentsOf: try await WineHome.makeDisc(in: temp.url))
        let bin = temp.url.appending(path: "Probe Game.bin")
        try RawDiscTests.rawImage(iso, audioSectors: 75).write(to: bin)
        let sectors = iso.count / 2048
        try Data("""
            FILE "Probe Game.bin" BINARY
              TRACK 01 MODE1/2352
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                INDEX 01 \(String(format: "%02d:%02d:%02d", sectors / 4500, sectors / 75 % 60, sectors % 75))
            """.utf8).write(to: temp.url.appending(path: "Probe Game.cue"))
        game.disc = temp.url.appending(path: "Probe Game.cue").path
        let with = try await AutoLaunch(paths: paths).play(game, runtime: runtime)
        let log = try String(contentsOf: #require(with.log), encoding: .utf8)
        #expect(log.contains("disc found in D:"), "\(log.suffix(1500))")
        #expect(with.working != nil)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["PLAVIOX_INTEGRATION"] == "1"), .serialized)
struct ScalingProbeTests {
    /// Plays the probe twice; returns the game as kept after it, and each run's log (read before the game and
    /// its logs are removed).
    func play(_ name: String, as copy: String) async throws -> (GameRecord, [AutoLaunch.Result], [String]) {
        let (paths, runtime) = try WineHome.current()
        let temp = try TempFolder()
        // The probe picks its mode from its file name (lowres-window.exe: a fixed window).
        let exe = temp.url.appending(path: "\(copy)/\(copy).exe")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Probes.url(name), to: exe)
        var game = try GameIdentifier(paths: paths).identify(executable: exe).record
        defer { try? GameRemover.removeFromApp(game.id, paths: paths) }
        var results: [AutoLaunch.Result] = []
        var logs: [String] = []
        for _ in 0..<2 {
            let result = try await AutoLaunch(paths: paths).play(game, runtime: runtime)
            results.append(result)
            logs.append(try String(contentsOf: #require(result.log), encoding: .utf8))
            game = try #require(try GameLibrary.load(from: paths.library)[game.id])
        }
        return (game, results, logs)
    }

    @Test func aLowResolutionFullScreenGameRunsWithoutSwitchingTheMac() async throws {
        let display = CGDisplayCopyDisplayMode(CGMainDisplayID())?.pixelWidth
        let (game, results, logs) = try await play("lowres-x86", as: "lowres-full")
        #expect(results.allSatisfy { $0.working != nil })
        #expect(game.window?.fullScreen == true)
        #expect(CGDisplayCopyDisplayMode(CGMainDisplayID())?.pixelWidth == display)
        let log = try #require(logs.last)
        #expect(log.contains("change 0; display 640x480"), "\(log.suffix(1500))")
    }

    @Test func aSmallWindowIsEnlargedFromItsSecondLaunch() async throws {
        let (game, results, logs) = try await play("lowres-x86", as: "lowres-window")
        let window = try #require(game.window)
        #expect(!window.fullScreen)
        #expect(results.allSatisfy { $0.working != nil })
        let (first, second) = (logs[0], logs[1])
        #expect(first.contains("[Plaviox] Scale 1x"))
        let expected = GameScaling.scale(setting: .auto, learned: window, dpiAware: false,
                                         screen: GameScaling.availableScreen())
        #expect(second.contains("[Plaviox] Scale \(expected.formatted(.number.precision(.fractionLength(0...2))))x"))
        // The game sees its own size either way.
        #expect(second.contains("window 646x512"), "\(second.suffix(1500))")
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["PLAVIOX_INTEGRATION"] == "1"), .serialized)
struct MigrationProbeTests {
    /// Needs two runtimes installed in PLAVIOX_HOME; with one, there is nothing to move between.
    @Test func aBottleMovesToANewerRuntimeWithWhatWasInstalled() async throws {
        let paths = AppPaths.standard()
        let installed = RuntimeInstaller(paths: paths).installedRuntimes()
        let manifest = try RuntimeManifest.bundled()
        let ids = Set(installed.map(\.id))
        let runtimes = manifest.runtimes.filter { ids.contains($0.id) }
        guard runtimes.count >= 2, let old = runtimes.first, let new = runtimes.last else { return }
        let temp = try TempFolder()
        let exe = temp.url.appending(path: "Game/game.exe")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Probes.url("d3d9-x86"), to: exe)
        let game = try GameIdentifier(paths: paths).identify(executable: exe).record
        defer { try? GameRemover.removeFromApp(game.id, paths: paths) }

        // On the old runtime, "install" something: a file in C:\Program Files and a key in HKLM.
        let bottles = BottleManager(paths: paths)
        let bottle = try await bottles.ensureBottle(for: game.id, runtime: old)
        let program = bottle.appending(path: "drive_c/Program Files/Probe/data.txt")
        try FileManager.default.createDirectory(at: program.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("installed".utf8).write(to: program)
        let oldWine = Wine(runtimeFolder: try #require(RuntimeInstaller(paths: paths).installed(old)))
        let environment = WineEnvironment.make(host: ProcessInfo.processInfo.environment, bottle: bottle.path)
        try await ProcessRunner.check(oldWine.wine.path, ["reg", "add", #"HKLM\Software\PlavioxTest"#, "/v", "Path",
                                                          "/d", #"C:\Program Files\Probe"#, "/f"],
                                      environment: environment)
        try await ProcessRunner.check(oldWine.wineserver.path, ["-w"], environment: environment)

        let result = try await AutoLaunch(paths: paths).play(game, runtime: new)
        #expect(result.working != nil)
        #expect(bottles.bottleInfo(for: game.id)?.runtime == new.id)
        #expect(bottles.bottleInfo(for: game.id)?.movedFrom == old.id)
        #expect(try String(contentsOf: program, encoding: .utf8) == "installed")
        let newWine = Wine(runtimeFolder: try #require(RuntimeInstaller(paths: paths).installed(new)))
        let query = try await ProcessRunner.run(newWine.wine.path, ["reg", "query", #"HKLM\Software\PlavioxTest"#],
                                                environment: environment)
        _ = try? await ProcessRunner.run(newWine.wineserver.path, ["-w"], environment: environment)
        let carried = query.output.contains(#"C:\Program Files\Probe"#)
        #expect(carried, "\(query.output)")
    }
}
