import Foundation
@testable import RumKit
import Testing

private func runtime(_ id: String, wine: String = "11.18", dxvk: String = "a", minMacOS: String = "15",
                     host: String = "github.com") -> RuntimeManifest.Runtime {
    func item(_ kind: RuntimeManifest.Component.Kind, _ version: String) -> RuntimeManifest.Component {
        // The hash follows the version, so "same version" means "same file".
        RuntimeManifest.Component(kind: kind, version: version, url: URL(string: "https://\(host)/\(kind)")!,
                                  sha256: sha256Hex(Data(version.utf8)), size: 1, license: "MIT", from: "",
                                  into: kind.rawValue)
    }
    return RuntimeManifest.Runtime(id: id, minRum: version("0.1"), minMacOS: version(minMacOS),
                                   components: [item(.wine, wine), item(.dxvk, dxvk)])
}

private func manifest(_ runtimes: RuntimeManifest.Runtime...) -> RuntimeManifest {
    RuntimeManifest(format: 1, runtimes: runtimes)
}

@Suite struct RuntimeCatalogTests {
    let rum = version("0.1"), mac = version("15.5")

    @Test func nothingInstalled() {
        let new = runtime("r2")
        #expect(RuntimeCatalog(installed: [], manifest: manifest(runtime("r1"), new), rum: rum, macOS: mac).status
            == .notInstalled(newest: new))
    }

    @Test func newestInstalledIsUpToDate() {
        let old = runtime("r1"), new = runtime("r2", wine: "11.20")
        let catalog = RuntimeCatalog(installed: [old, new], manifest: manifest(old, new), rum: rum, macOS: mac)
        #expect(catalog.status == .upToDate(new))
        #expect(!catalog.updateAvailable)
    }

    @Test func olderInstalledOffersUpdate() {
        let old = runtime("r1"), new = runtime("r2", wine: "11.20")
        let catalog = RuntimeCatalog(installed: [old], manifest: manifest(old, new), rum: rum, macOS: mac)
        #expect(catalog.status == .updateAvailable(current: old, newest: new))
    }

    @Test func runtimeTheListDroppedStillCountsAsOlder() {
        let gone = runtime("r0"), new = runtime("r2")
        #expect(RuntimeCatalog(installed: [gone], manifest: manifest(new), rum: rum, macOS: mac).status
            == .updateAvailable(current: gone, newest: new))
    }

    @Test func noUpdateThatThisMacCantRun() {
        let old = runtime("r1"), tahoeOnly = runtime("r2", minMacOS: "26")
        #expect(RuntimeCatalog(installed: [old], manifest: manifest(old, tahoeOnly), rum: rum, macOS: mac).status
            == .upToDate(old))
    }

    @Test func changesListOnlyWhatDiffers() {
        let old = runtime("r1", wine: "11.18", dxvk: "a"), new = runtime("r2", wine: "11.20", dxvk: "a")
        #expect(RuntimeCatalog.changes(from: old, to: new)
            == [.init(kind: .wine, oldVersion: "11.18", newVersion: "11.20")])
    }
}

@Suite struct ManifestUpdaterTests {
    @Test func isDueAfterADayOrWhenNeverChecked() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ManifestUpdater.isDue(lastChecked: nil, now: now))
        #expect(!ManifestUpdater.isDue(lastChecked: now.addingTimeInterval(-3600), now: now))
        #expect(ManifestUpdater.isDue(lastChecked: now.addingTimeInterval(-25 * 3600), now: now))
        #expect(ManifestUpdater.isDue(lastChecked: now.addingTimeInterval(3600), now: now))
    }

    @Test func cacheWinsUnlessTheAppKnowsNewerRuntimes() {
        let bundled = manifest(runtime("r1"))
        let fetched = manifest(runtime("r1"), runtime("r2"))
        #expect(ManifestUpdater.choose(bundled: bundled, cached: fetched) == fetched)
        #expect(ManifestUpdater.choose(bundled: manifest(runtime("r1"), runtime("r3")), cached: fetched).runtimes
            .map(\.id) == ["r1", "r3"])
        #expect(ManifestUpdater.choose(bundled: bundled, cached: nil) == bundled)
    }

    func serve(_ manifest: RuntimeManifest) throws -> (URL, URLSessionConfiguration) {
        let data = try JSONEncoder().encode(manifest)
        let server = StubProtocol.register { _ in (200, [:], data) }
        return (URL(string: "stub://\(server.host)/m.json")!, server.configuration)
    }

    @Test func checkFetchesAndCaches() async throws {
        let temp = try TempFolder()
        let paths = RumPaths(root: temp.url, games: temp.url)
        let fetched = manifest(runtime("r1"), runtime("r2"))
        let (url, configuration) = try serve(fetched)
        let updater = ManifestUpdater(paths: paths, url: url, configuration: configuration,
                                      bundled: { manifest(runtime("r1")) })
        let now = Date(timeIntervalSince1970: 2_000_000)

        #expect(try await updater.check(now: now) == fetched)
        #expect(updater.cached()?.checkedAt == now)
        #expect(try updater.current() == fetched)
    }

    @Test func downloadsOutsideGitHubAreRefused() async throws {
        let temp = try TempFolder()
        let (url, configuration) = try serve(manifest(runtime("r9", host: "evil.example.com")))
        let updater = ManifestUpdater(paths: RumPaths(root: temp.url, games: temp.url), url: url,
                                      configuration: configuration, bundled: { manifest(runtime("r1")) })
        await #expect(throws: ManifestError.self) { try await updater.check() }
        #expect(updater.cached() == nil)
    }
}
