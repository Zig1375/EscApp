import Foundation
import RumCLI
import RumKit
import Testing

@Suite struct RumCommandTests {
    let command = RumCommand(
        paths: RumPaths.standard(environment: ["RUM_HOME": "/tmp/rum-test"]),
        host: ["HOME": "/Users/test", "SECRET_TOKEN": "x"]
    )

    @Test func version() {
        #expect(command.run(["version"]).stdout == "\(RumCommand.version)\n")
    }

    @Test func pathsHonourRumHome() {
        let output = command.run(["paths"])
        #expect(output.status == 0)
        #expect(output.stdout.contains("Bottles: /tmp/rum-test/Bottles/"))
    }

    @Test func plan() {
        #expect(command.run(["plan", "--arch", "x86", "--dx", "11"]).stdout == "DXMT → WineD3D\n")
        #expect(command.run(["plan", "--arch", "x64", "--dx", "9", "--dx", "11"]).stdout
            == "DXVK → DXMT → WineD3D\n")
        #expect(command.run(["plan", "--arch", "x64", "--dx", "12"]).status == 1)
        #expect(command.run(["plan", "--arch", "arm"]).status == 1)
    }

    @Test func envDropsHostSecrets() {
        let output = command.run(["env", "--bottle", "/b", "--backend", "dxmt"])
        #expect(output.status == 0)
        #expect(output.stdout.contains("WINEPREFIX=/b"))
        #expect(!output.stdout.contains("SECRET_TOKEN"))
    }

    @Test func unknownInputFails() {
        #expect(command.run([]).status == 1)
        #expect(command.run(["frobnicate"]).status == 1)
        #expect(command.run(["env", "--bottle", "/b", "--backend", "dxvk", "--nope"]).stderr.contains("--nope"))
    }
}
