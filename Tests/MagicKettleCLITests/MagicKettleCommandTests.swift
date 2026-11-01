import Foundation
import MagicKettleCLI
import MagicKettleKit
import Testing

@Suite struct MagicKettleCommandTests {
    let command = MagicKettleCommand(
        paths: AppPaths.standard(environment: ["MAGICKETTLE_HOME": "/tmp/magickettle-test"]),
        host: ["HOME": "/Users/test", "SECRET_TOKEN": "x"]
    )

    @Test func version() async {
        #expect(await command.run(["version"]).stdout == "\(MagicKettleCommand.version)\n")
    }

    /// The app's version lives in project.yml; the CLI has no bundle to read it from, so it repeats it.
    @Test func versionMatchesTheApp() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let spec = try String(contentsOf: root.appending(path: "project.yml"), encoding: .utf8)
        #expect(spec.contains("MAGICKETTLE_VERSION: \"\(MagicKettleCommand.version)\""))
    }

    @Test func pathsHonourMagicKettleHome() async {
        let output = await command.run(["paths"])
        #expect(output.status == 0)
        #expect(output.stdout.contains("Bottles: /tmp/magickettle-test/Bottles/"))
    }

    @Test func plan() async {
        #expect(await command.run(["plan", "--arch", "x86", "--dx", "11"]).stdout == "DXVK → DXMT → WineD3D\n")
        #expect(await command.run(["plan", "--arch", "x64", "--dx", "9", "--dx", "11"]).stdout
            == "DXVK → DXMT → WineD3D\n")
        #expect(await command.run(["plan", "--arch", "x64", "--dx", "12"]).status == 1)
        #expect(await command.run(["plan", "--arch", "arm"]).status == 1)
    }

    @Test func envDropsHostSecrets() async {
        let output = await command.run(["env", "--bottle", "/b"])
        #expect(output.status == 0)
        #expect(output.stdout.contains("WINEPREFIX=/b"))
        #expect(!output.stdout.contains("SECRET_TOKEN"))
    }

    @Test func runtimeStatusAndRosettaConsent() async throws {
        let manifest = try RuntimeManifest.decode(Data("""
            {"format": 1, "runtimes": [{"id": "r1", "minApp": "0.1", "minMacOS": "15", "components": []}]}
            """.utf8))
        let noRosetta = MagicKettleCommand(
            paths: AppPaths.standard(environment: ["MAGICKETTLE_HOME": "/tmp/magickettle-test-\(UUID().uuidString)"]),
            manifest: { manifest }, rosettaInstalled: { false })
        let status = await noRosetta.run(["runtime", "status"])
        #expect(status.stdout.contains("Rosetta: not installed"))
        #expect(status.stdout.contains("Runtime r1: not installed"))
        // Installing Rosetta accepts Apple's license, so it never happens without the flag.
        let install = await noRosetta.run(["runtime", "install"])
        #expect(install.status == 1)
        #expect(install.stderr.contains("--accept-rosetta-license"))
    }

    @Test func storesStartUninstalled() async {
        let home = MagicKettleCommand(
            paths: AppPaths.standard(environment: ["MAGICKETTLE_HOME": "/tmp/magickettle-test-\(UUID().uuidString)"]))
        let list = await home.run(["store", "list"])
        #expect(list.status == 0)
        #expect(list.stdout.contains("steam     Steam: not installed"))
        #expect(list.stdout.contains("epic      Epic Games Store: not installed"))
        #expect(await home.run(["store", "sync"]).stdout == "No store games installed.\n")
        #expect(await home.run(["store", "install", "origin"]).status == 1)
        #expect(await home.run(["store", "install", "gog"]).status == 1)
        #expect(await home.run(["store"]).status == 1)
    }

    @Test func unknownInputFails() async {
        #expect(await command.run([]).status == 1)
        #expect(await command.run(["frobnicate"]).status == 1)
        #expect(await command.run(["env", "--bottle", "/b", "--nope"]).stderr.contains("--nope"))
    }

    // MARK: run and install, without Wine

    static let probes = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../Fixtures/probes").standardizedFileURL

    /// A command on a fresh home with a runtime that isn't installed: everything up to starting Wine runs.
    func scratch() throws -> (MagicKettleCommand, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "magickettle-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let manifest = try RuntimeManifest.decode(Data("""
            {"format": 1, "runtimes": [{"id": "r1", "minApp": "0.1", "minMacOS": "15", "components": []}]}
            """.utf8))
        let command = MagicKettleCommand(paths: AppPaths.standard(environment: ["MAGICKETTLE_HOME": home.path]),
                                    manifest: { manifest }, rosettaInstalled: { true })
        return (command, home)
    }

    /// The probe copied into its own folder, so its `.magickettle` marker lands in the scratch home.
    func game(in home: URL) throws -> URL {
        let exe = home.appending(path: "Games/Probe/probe.exe")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.probes.appending(path: "d3d9-x86.exe"), to: exe)
        return exe
    }

    @Test func runKeepsScaleAndDiscForTheGame() async throws {
        let (command, home) = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let exe = try game(in: home)
        let output = await command.run(["run", exe.path, "--scale", "on", "--disc", "/Games/Probe.cue"])
        // No runtime here, so it stops before Wine, with the settings already kept.
        #expect(output.status == 1)
        let library = try GameLibrary.load(from: home.appending(path: "Games.json"))
        #expect(library.games.first?.scaling == .on)
        #expect(library.games.first?.disc == "/Games/Probe.cue")

        _ = await command.run(["run", exe.path, "--scale", "auto"])
        #expect(try GameLibrary.load(from: home.appending(path: "Games.json")).games.first?.scaling == nil)
    }

    @Test func runRefusesUnknownChoices() async throws {
        let (command, home) = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let exe = try game(in: home)
        #expect(await command.run(["run", exe.path, "--scale", "huge"]).stderr.contains("Unknown scaling: huge"))
        #expect(await command.run(["run", exe.path, "--backend", "metal"]).stderr.contains("Unknown backend: metal"))
    }

    @Test func installTellsInstallersFromGames() async throws {
        let (command, home) = try scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(await command.run(["install"]).stderr.contains("install needs"))
        let game = await command.run(["install", Self.probes.appending(path: "d3d9-x86.exe").path])
        #expect(game.stderr.contains("doesn't look like an installer"))
        // An installer gets as far as the runtime, which isn't installed here.
        let setup = await command.run(["install", Self.probes.appending(path: "setup-x86.exe").path])
        #expect(setup.status == 1)
        #expect(setup.stderr.contains("r1"))
        #expect(try GameLibrary.load(from: home.appending(path: "Games.json")).games.isEmpty)
    }
}
