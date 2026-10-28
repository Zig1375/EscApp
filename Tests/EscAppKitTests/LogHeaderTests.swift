@testable import EscAppKit
import Foundation
import Testing

@Suite struct LogHeaderTests {
    static let mac = SystemInfo(app: "0.1.0 (1)", macOS: "27.0.1 (26A434)", modelName: "MacBook Pro (16-inch, 2023)",
                                modelID: "Mac14,6", chip: "Apple M2 Max", performanceCores: 8, efficiencyCores: 4,
                                memoryBytes: 32 << 30, language: "ru-RU", rosetta: true)

    @Test func namesTheMacTheAppAndEveryComponent() throws {
        let manifest = try RuntimeManifest.bundled()
        let runtime = try #require(manifest.runtimes.last)
        let lines = LogHeader.lines(system: Self.mac, runtime: runtime)

        #expect(Array(lines.prefix(5)) == [
            "[EscApp] EscApp 0.1.0 (1)",
            "[EscApp] macOS 27.0.1 (26A434)",
            "[EscApp] Mac MacBook Pro (16-inch, 2023) (Mac14,6)",
            "[EscApp] Chip Apple M2 Max, 8P + 4E cores, 32 GB memory",
            "[EscApp] Mac language ru-RU, Rosetta installed",
        ])
        #expect(lines.contains("[EscApp] Runtime \(runtime.id)"))
        for component in runtime.components {
            #expect(lines.contains { $0.hasPrefix("[EscApp] Component \(component.kind.rawValue) \(component.version) ")
                && $0.hasSuffix(String(component.sha256.prefix(12))) })
        }
    }

    @Test func namesTheD3DMetalThePlayerAdded() {
        let installed = D3DMetal.Installed(version: "3.0",
                                           source: "Evaluation_environment_for_Windows_games_3.0.dmg")
        #expect(LogHeader.d3dmetalLine(installed)
            == "[EscApp] D3DMetal 3.0 from Evaluation_environment_for_Windows_games_3.0.dmg")
        #expect(LogHeader.d3dmetalLine(nil) == "[EscApp] D3DMetal not added")
    }

    @Test func aMacWithoutAMarketingNameShowsItsModel() {
        var mac = Self.mac
        mac.modelName = ""
        mac.efficiencyCores = 0
        #expect(mac.summary == "Mac14,6, Apple M2 Max, 8 cores, 32 GB memory")
        #expect(LogHeader.lines(system: mac, runtime: nil).last == "[EscApp] Runtime unknown")
    }

    @Test func thisMacIsRead() {
        let mac = SystemInfo.current
        #expect(!mac.macOS.isEmpty && mac.modelID != "?" && mac.chip != "?" && mac.performanceCores > 0)
        #expect(mac.memoryBytes > 0)
    }

    @Test func theLaunchLineStillLeadsSoHistoryFindsIt() {
        let head = (["[EscApp] Launch 2026-10-23T19:40:00Z"] + LogHeader.lines(system: Self.mac, runtime: nil)
            + ["[EscApp] Backend dxvk"]).joined(separator: "\n")
        #expect(LaunchHistory.parse(head: head, tail: "", log: URL(filePath: "/l.log"))?.backend == .dxvk)
    }
}
