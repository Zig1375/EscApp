import EscAppCLI
import EscAppKit
import Foundation
import Testing

@Suite struct EscAppCommandTests {
    let command = EscAppCommand(
        paths: AppPaths.standard(environment: ["ESCAPP_HOME": "/tmp/escapp-test"]),
        host: ["HOME": "/Users/test", "SECRET_TOKEN": "x"]
    )

    @Test func version() async {
        #expect(await command.run(["version"]).stdout == "\(EscAppCommand.version)\n")
    }

    @Test func pathsHonourEscAppHome() async {
        let output = await command.run(["paths"])
        #expect(output.status == 0)
        #expect(output.stdout.contains("Bottles: /tmp/escapp-test/Bottles/"))
    }

    @Test func plan() async {
        #expect(await command.run(["plan", "--arch", "x86", "--dx", "11"]).stdout == "DXMT → DXVK → WineD3D\n")
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
        let noRosetta = EscAppCommand(
            paths: AppPaths.standard(environment: ["ESCAPP_HOME": "/tmp/escapp-test-\(UUID().uuidString)"]),
            manifest: { manifest }, rosettaInstalled: { false })
        let status = await noRosetta.run(["runtime", "status"])
        #expect(status.stdout.contains("Rosetta: not installed"))
        #expect(status.stdout.contains("Runtime r1: not installed"))
        // Installing Rosetta accepts Apple's license, so it never happens without the flag.
        let install = await noRosetta.run(["runtime", "install"])
        #expect(install.status == 1)
        #expect(install.stderr.contains("--accept-rosetta-license"))
    }

    @Test func unknownInputFails() async {
        #expect(await command.run([]).status == 1)
        #expect(await command.run(["frobnicate"]).status == 1)
        #expect(await command.run(["env", "--bottle", "/b", "--nope"]).stderr.contains("--nope"))
    }
}
