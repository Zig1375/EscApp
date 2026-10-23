import ExePortKit
import Foundation
import Testing

@Suite struct AppPathsTests {
    let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)

    @Test func standardLayout() {
        let paths = AppPaths.standard(home: home, environment: [:])
        #expect(paths.root.path() == "/Users/test/Library/Application%20Support/ExePort/")
        #expect(paths.games.path() == "/Users/test/Games/")
        #expect(paths.library.lastPathComponent == "Games.json")
        #expect(paths.template(forRuntime: "11.18-1").path(percentEncoded: false)
            == "/Users/test/Library/Application Support/ExePort/Templates/11.18-1/")
    }

    @Test func exeportHomeKeepsEverythingInsideIt() {
        let paths = AppPaths.standard(home: home, environment: ["EXEPORT_HOME": "/tmp/scratch"])
        #expect(paths.root.path() == "/tmp/scratch/")
        #expect(paths.games.path() == "/tmp/scratch/Games/")
        let id = GameID.make()
        #expect(paths.bottle(forGame: id).path() == "/tmp/scratch/Bottles/\(id)/")
    }
}

@Suite struct GameIDTests {
    @Test func roundTripsThroughJSON() throws {
        let id = GameID.make()
        let data = try JSONEncoder().encode(["id": id])
        #expect(try JSONDecoder().decode([String: GameID].self, from: data)["id"] == id)
    }

    @Test(arguments: ["../..", "", "6f1c0000-0000-0000-0000-000000000000", "Steam"])
    func rejectsAnythingButAnUppercaseUUID(_ raw: String) {
        #expect(GameID(rawValue: raw) == nil)
    }

    @Test func decodingAPathFails() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([String: GameID].self, from: Data(#"{"id":"../../Library"}"#.utf8))
        }
    }
}

@Suite struct WindowsVersionTests {
    @Test func defaultIsWindows10() {
        #expect(WindowsVersion.default == .windows10)
    }

    @Test func wineValuesRoundTrip() {
        for version in WindowsVersion.allCases {
            #expect(WindowsVersion(wineValue: version.wineValue) == version)
        }
        #expect(WindowsVersion(wineValue: "WIN10") == .windows10)
        #expect(WindowsVersion(wineValue: "win95") == nil)
    }
}

@Suite struct WineEnvironmentTests {
    let host = ["HOME": "/Users/test", "PATH": "/usr/bin", "DYLD_INSERT_LIBRARIES": "/evil.dylib",
                "WINEPREFIX": "/somewhere/else"]

    @Test func onlyAllowlistedHostVariablesPass() {
        let env = WineEnvironment.make(host: host, bottle: "/b")
        #expect(env["HOME"] == "/Users/test")
        #expect(env["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(env["WINEPREFIX"] == "/b")
    }

    @Test func menuBuilderIsAlwaysOff() {
        #expect(WineEnvironment.make(host: [:], bottle: "/b")["WINEDLLOVERRIDES"] == "winemenubuilder.exe=d")
    }

    @Test func userSettingsWinLast() {
        let env = WineEnvironment.make(host: host, bottle: "/b",
                                       extra: ["WINEDLLOVERRIDES": "dinput8=n,b", "DXVK_HUD": "fps"])
        #expect(env["WINEDLLOVERRIDES"] == "dinput8=n,b")
        #expect(env["DXVK_HUD"] == "fps")
    }

    @Test func verboseLogKeepsWineOutput() {
        #expect(WineEnvironment.make(host: [:], bottle: "/b")["WINEDEBUG"] == "-all")
        #expect(WineEnvironment.make(host: [:], bottle: "/b", verboseLog: true)["WINEDEBUG"]
            != "-all")
    }
}
