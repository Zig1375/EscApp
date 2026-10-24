@testable import EscAppKit
import Foundation
import Testing

// A store game on real Wine, without a store account: the D3D9 probe stands in for a GOG game in GOG Galaxy's
// bottle, while something else keeps that bottle's Wine running the way a store's client does. Same opt-in as
// `InstallProbeTests`; skipped when the scratch home has GOG Galaxy installed for real.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ESCAPP_INTEGRATION"] == "1"), .serialized)
struct StoreProbeTests {
    @Test func aStoreGameEndsWithItsOwnProcessesWhileTheClientRuns() async throws {
        let (paths, runtime) = try WineHome.current()
        let store = Store.gog
        let stores = StoreClient(paths: paths)
        try #require(!stores.isInstalled(store), "GOG Galaxy is installed in ESCAPP_HOME; this test would remove it")
        let bottle = try await BottleManager(paths: paths).ensureBottle(for: store.bottleID, runtime: runtime)
        defer { try? FileManager.default.removeItem(at: bottle) }
        let drive = bottle.appending(path: "drive_c", directoryHint: .isDirectory)
        let galaxy = drive.appending(path: store.clientPaths[0])
        let folder = drive.appending(path: "GOG Games/Store Probe", directoryHint: .isDirectory)
        for directory in [galaxy.deletingLastPathComponent(), folder] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: Probes.url("d3d11-x86"), to: galaxy)
        let exe = folder.appending(path: "probe.exe")
        try FileManager.default.copyItem(at: Probes.url("d3d9-x86"), to: exe)

        // The "client": waits in the bottle until its input closes, in the Wine tree the game will run in (the
        // first its rules pick: a store game gets one try).
        guard case let .attempts(plan) = BackendPlan.forTraits(try ExecutableInfo.read(exe).traits),
              let backend = plan.first else { throw CancellationError() }
        let folderOfRuntime = try #require(RuntimeInstaller(paths: paths).installed(runtime))
        let wine = try BackendTree.wine(for: backend, runtimeFolder: folderOfRuntime)
        let holder = Process()
        let input = Pipe()
        holder.executableURL = wine.wine
        holder.arguments = ["cmd.exe", "/c", "pause"]
        holder.environment = WineEnvironment.make(host: ProcessInfo.processInfo.environment, bottle: bottle.path)
        holder.standardInput = input
        holder.standardOutput = FileHandle.nullDevice
        holder.standardError = FileHandle.nullDevice
        try holder.run()
        defer { try? input.fileHandleForWriting.close() }
        let deadline = Date().addingTimeInterval(30)
        while !stores.isRunning(store), Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        try #require(stores.isRunning(store), "The stand-in client didn't start")

        var record = GameRecord(id: .make(), name: "Store Probe", executable: exe.path(percentEncoded: false),
                                folder: folder.path(percentEncoded: false), hasMarker: false, addedAt: Date())
        record.store = store
        record.storeID = "1"
        // About 25 s of frames: longer than a window has to hold to count as working.
        record.arguments = "1500"
        try GameLibrary.modify(paths.library) { $0[record.id] = record }
        defer { try? GameLibrary.modify(paths.library) { $0[record.id] = nil } }

        let started = Date()
        let result = try await AutoLaunch(paths: paths).play(record, runtime: runtime)
        #expect(result.working == backend)
        #expect(result.attempts.count == 1)
        // Over once the game's own process was: the client's Wine kept running all along.
        #expect(stores.isRunning(store))
        #expect(Date().timeIntervalSince(started) < 60)
        let log = try String(contentsOf: #require(result.log), encoding: .utf8)
        #expect(log.contains("[EscApp] Store GOG Galaxy 1"))

        await stores.shutDown(store)
        #expect(!stores.isRunning(store))
    }
}
