@testable import ExePortKit
import Foundation
import Testing

/// The probe executables in `Tests/Fixtures/probes` (built by its `build.sh`, checked in) are real PE files with
/// known contents, so they test the exe reader without any game.
enum Probes {
    static let folder = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../Fixtures/probes").standardizedFileURL

    static func url(_ name: String) -> URL { folder.appending(path: "\(name).exe") }
}

@Suite struct ExecutableInfoTests {
    @Test(arguments: [("d3d11-x64", ExecutableInfo.Format.pe64, ExecutableTraits.DirectX.d3d11),
                      ("d3d11-x86", .pe32, .d3d11), ("d3d9-x64", .pe64, .d3d9), ("d3d9-x86", .pe32, .d3d9)])
    func readsFormatAndDirectX(_ name: String, _ format: ExecutableInfo.Format, _ directX: ExecutableTraits.DirectX)
        throws {
        let info = try ExecutableInfo.read(Probes.url(name))
        #expect(info.format == format)
        #expect(info.directX == [directX])
        #expect(info.imports.contains("kernel32.dll"))
    }

    @Test func readsNameManifestAndIcon() throws {
        let info = try ExecutableInfo.read(Probes.url("d3d11-x86"))
        #expect(info.productName == "ExePort Probe")
        #expect(info.dpiAware)
        let icon = try #require(info.icon)
        // A valid .ico: reserved 0, type 1, one 32x32 image.
        #expect(icon.u16le(0) == 0 && icon.u16le(2) == 1 && icon.u16le(4) == 1)
        #expect(icon[icon.startIndex + 6] == 32)
    }

    @Test func plansMatchTheRules() throws {
        let plan = { (name: String) in BackendPlan.forTraits(try ExecutableInfo.read(Probes.url(name)).traits) }
        #expect(try plan("d3d11-x64") == .attempts([.dxvk, .dxmt, .wined3d]))
        #expect(try plan("d3d11-x86") == .attempts([.dxmt, .dxvk, .wined3d]))
        #expect(try plan("d3d9-x86") == .attempts([.wined3d]))
    }

    @Test func otherFormats() throws {
        let temp = try TempFolder()
        func write(_ bytes: [UInt8], _ name: String) throws -> URL {
            let url = temp.url.appending(path: name)
            try Data(bytes).write(to: url)
            return url
        }
        var dos = [UInt8](repeating: 0, count: 128)
        dos[0] = 0x4D; dos[1] = 0x5A
        #expect(try ExecutableInfo.read(write(dos, "dos.exe")).format == .dos)
        var win16 = dos
        win16[0x3C] = 0x40; win16[0x40] = 0x4E; win16[0x41] = 0x45  // "NE" at 0x40
        #expect(try ExecutableInfo.read(write(win16, "win16.exe")).format == .win16)
        #expect(throws: ExecutableError.notAnExecutable) {
            try ExecutableInfo.read(write(Array("#!/bin/sh".utf8), "script.exe"))
        }
    }

    @Test func dpiAwarenessFromManifest() {
        #expect(PEReader.declaresDPIAwareness("<dpiAware>true/pm</dpiAware>"))
        #expect(PEReader.declaresDPIAwareness("<dpiAwareness>PerMonitorV2</dpiAwareness>"))
        #expect(!PEReader.declaresDPIAwareness("<dpiAware>false</dpiAware>"))
        #expect(!PEReader.declaresDPIAwareness("<assembly/>"))
    }
}

/// Runs the probes on real Wine. Opt in with `EXEPORT_INTEGRATION=1` and a `EXEPORT_HOME` whose runtime is installed
/// (`exeport runtime install`); windows open for a couple of seconds each.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["EXEPORT_INTEGRATION"] == "1"), .serialized)
struct ProbeLaunchTests {
    @Test(arguments: [("d3d11-x64", GraphicsBackend.dxvk), ("d3d11-x64", .dxmt), ("d3d11-x86", .dxmt),
                      ("d3d11-x86", .wined3d), ("d3d9-x64", .wined3d), ("d3d9-x86", .wined3d)])
    func probeRendersFrames(_ name: String, _ backend: GraphicsBackend) async throws {
        let paths = AppPaths.standard()
        let runtime = try #require(RuntimeCatalog(
            installed: RuntimeInstaller(paths: paths).installedRuntimes(), manifest: RuntimeManifest.bundled(),
            app: Version("0.1")!, macOS: Version("15")!).current, "No runtime installed in EXEPORT_HOME")
        // A copy, so the probe's .exeport lands in a scratch folder rather than in the repository.
        let temp = try TempFolder()
        let exe = temp.url.appending(path: "\(name).exe")
        try FileManager.default.copyItem(at: Probes.url(name), to: exe)
        let game = try GameIdentifier(paths: paths).identify(executable: exe).record
        defer { try? GameRemover.removeFromApp(game.id, paths: paths) }

        let launcher = GameLauncher(paths: paths)
        let outcome = try await launcher.run(launcher.prepare(game, runtime: runtime, backend: backend))
        let log = try String(contentsOf: outcome.log, encoding: .utf8)
        #expect(outcome.exitCode == 0, "\(log.suffix(2000))")
        #expect(log.contains("PROBE \(name.hasPrefix("d3d11") ? "d3d11" : "d3d9") OK"))
    }
}

/// The retry loop on real Wine (same opt-in as `ProbeLaunchTests`).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["EXEPORT_INTEGRATION"] == "1"), .serialized)
struct AutoLaunchProbeTests {
    func play(_ name: String) async throws -> AutoLaunch.Result {
        let paths = AppPaths.standard()
        let runtime = try #require(RuntimeCatalog(
            installed: RuntimeInstaller(paths: paths).installedRuntimes(), manifest: RuntimeManifest.bundled(),
            app: Version("0.1")!, macOS: Version("15")!).current, "No runtime installed in EXEPORT_HOME")
        let temp = try TempFolder()
        let exe = temp.url.appending(path: "\(name).exe")
        try FileManager.default.copyItem(at: Probes.url(name), to: exe)
        let game = try GameIdentifier(paths: paths).identify(executable: exe).record
        defer { try? GameRemover.removeFromApp(game.id, paths: paths) }
        return try await AutoLaunch(paths: paths).play(game, runtime: runtime)
    }

    @Test func aWorkingGameNeedsOneAttempt() async throws {
        let result = try await play("d3d9-x64")
        #expect(result.working == .wined3d)
        #expect(result.attempts.count == 1)
    }

    @Test func aCrashingGameTriesEveryBackend() async throws {
        let result = try await play("crash-x64")
        #expect(result.working == nil)
        #expect(result.attempts.map(\.backend) == [.dxvk, .dxmt, .wined3d])
        #expect(result.attempts.allSatisfy { $0.failure != nil && $0.diagnosis.problem == .crash })
    }

    @Test func aMissingFileStopsAtOnce() async throws {
        let result = try await play("missing-x64")
        #expect(result.working == nil)
        #expect(result.attempts.count == 1)
        #expect(result.attempts.first?.diagnosis.problem == .missingFile("exeport_missing.dll"))
    }
}
