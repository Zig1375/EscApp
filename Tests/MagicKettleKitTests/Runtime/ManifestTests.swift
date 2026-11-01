import Foundation
@testable import MagicKettleKit
import Testing

@Suite struct VersionTests {
    @Test func comparesNumerically() {
        #expect(version("0.10.0") > version("0.9.9"))
        #expect(version("15") == version("15.0.0"))
        #expect(Set([version("15"), version("15.0.0")]).count == 1)
        #expect(version("11.18") < version("12.0"))
    }

    @Test(arguments: ["", "1..2", "1.a", "-1", "1.0-beta"])
    func rejectsGarbage(_ string: String) {
        #expect(Version(string) == nil)
    }
}

@Suite struct ManifestTests {
    static let sha = String(repeating: "a", count: 64)

    func manifest(id: String = "wine-1", url: String = "https://example.com/w.tar.xz", sha: String = sha,
                  from: String = "", into: String = "wine", format: Int = 1) -> Data {
        Data("""
        {"format": \(format), "runtimes": [{"id": "\(id)", "minApp": "0.1.0", "minMacOS": "15.0", "components": [
          {"kind": "wine", "version": "1", "url": "\(url)", "sha256": "\(sha)", "size": 10,
           "license": "MIT", "from": "\(from)", "into": "\(into)"}]}]}
        """.utf8)
    }

    @Test func bundledManifestIsValidAndHasEveryComponent() throws {
        let manifest = try RuntimeManifest.bundled()
        let runtime = try #require(manifest.newest(forApp: version("0.1.0"), macOS: version("15.0")))
        // Gcenx's Wine already carries the Wine Mono and Gecko versions it expects, so they aren't separate.
        #expect(Set(runtime.components.map(\.kind)) == [.wine, .dxvk, .dxmt])
        #expect(runtime.components.first?.kind == .wine)
    }

    @Test func newestPicksTheLastUsableRuntime() throws {
        let json = """
        {"format": 1, "runtimes": [
          {"id": "old", "minApp": "0.1", "minMacOS": "15", "components": []},
          {"id": "new", "minApp": "0.2", "minMacOS": "15", "components": []},
          {"id": "tahoe", "minApp": "0.1", "minMacOS": "26", "components": []}]}
        """
        let manifest = try RuntimeManifest.decode(Data(json.utf8))
        let v01 = version("0.1"), v02 = version("0.2"), sequoia = version("15.5"), tahoe = version("26.0")
        #expect(manifest.newest(forApp: v01, macOS: sequoia)?.id == "old")
        #expect(manifest.newest(forApp: v02, macOS: sequoia)?.id == "new")
        #expect(manifest.newest(forApp: v02, macOS: tahoe)?.id == "tahoe")
    }

    @Test func acceptsAWellFormedEntry() throws {
        _ = try RuntimeManifest.decode(manifest(from: "Wine Staging.app/Contents/Resources/wine"))
    }

    @Test func rejectsNewerFormat() {
        #expect(throws: ManifestError.newerFormat(2)) { try RuntimeManifest.decode(manifest(format: 2)) }
    }

    @Test(arguments: [
        ("id", "../x"), ("id", ".hidden"), ("url", "http://example.com/w.tar.xz"),
        ("sha", "ABC"), ("sha", String(repeating: "A", count: 64)),
        ("into", "../outside"), ("into", "/abs"), ("into", ""), ("from", "a/../../b"),
    ])
    func rejectsUnsafeEntries(_ field: String, _ value: String) {
        let data: Data = switch field {
        case "id": manifest(id: value)
        case "url": manifest(url: value)
        case "sha": manifest(sha: value)
        case "into": manifest(into: value)
        default: manifest(from: value)
        }
        #expect(throws: ManifestError.self) { try RuntimeManifest.decode(data) }
    }
}
