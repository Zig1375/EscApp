@testable import EscAppKit
import Foundation
import Synchronization
import Testing

extension AutoLaunchTests {
    /// The game remembered as working with WineD3D, its window learned, and its exe as it was then.
    func rememberedWithWineD3D(stamp: GameRecord.ExeStamp?) throws {
        try GameLibrary.modify(paths.library) { library in
            library[game.id]?.backend = .wined3d
            library[game.id]?.window = Self.window
            library[game.id]?.exeStamp = stamp
        }
    }

    /// Plays the game as the library has it now, as the app does.
    func playStored(_ starter: FakeStarter, events: @escaping @Sendable (AutoLaunch.Event) -> Void = { _ in })
        async throws -> AutoLaunch.Result {
        let stored = try #require(try GameLibrary.load(from: paths.library)[game.id])
        return try await AutoLaunch(paths: paths, starter: starter, windows: starter.windows,
                                    measure: { _ in Self.window }, picture: { _ in nil }, cpu: { _ in nil },
                                    fullScreen: { _ in false }, timing: timing)
            .play(stored, runtime: runtime, events: events)
    }

    @Test func anUpdatedExeIsTunedAgain() async throws {
        // The exe isn't what it was when WineD3D worked: a patch.
        try rememberedWithWineD3D(stamp: .init(size: 1, modified: 1))
        let starter = try FakeStarter([.dxvk: .works], logs: logs())
        let events = Mutex<[String]>([])
        let result = try await playStored(starter) { event in
            if case let .tuning(order) = event { events.withLock { $0.append(order.map(\.rawValue).joined()) } }
        }
        // As a first launch: the usual order from the top, not the remembered WineD3D first.
        #expect(starter.started.first?.0 == .dxvk)
        #expect(events.withLock { $0 }.count == 1)
        #expect(result.working == .dxvk)
        let record = try #require(try GameLibrary.load(from: paths.library)[game.id])
        #expect(record.exeStamp == GameRecord.ExeStamp(of: URL(filePath: game.executable)))
    }

    @Test func theSameExeKeepsWhatWasFound() async throws {
        try rememberedWithWineD3D(stamp: GameRecord.ExeStamp(of: URL(filePath: game.executable)))
        let starter = try FakeStarter([.wined3d: .works], logs: logs())
        _ = try await playStored(starter)
        #expect(starter.started.first?.0 == .wined3d)
    }

    @Test func aGameThatWorkedKeepsItsBackendWhenItFailsOnce() async throws {
        try rememberedWithWineD3D(stamp: GameRecord.ExeStamp(of: URL(filePath: game.executable)))
        let starter = try FakeStarter([.wined3d: .crashes(), .dxvk: .works], logs: logs())
        let result = try await playStored(starter)
        // No other backend is tried, and none replaces the one that worked.
        #expect(starter.started.map(\.0) == [.wined3d])
        #expect(result.working == nil)
        #expect(try remembered() == .wined3d)
    }

    @Test func aGameFromBeforeStampsGetsOneWithoutForgetting() async throws {
        try rememberedWithWineD3D(stamp: nil)
        let starter = try FakeStarter([.wined3d: .works], logs: logs())
        _ = try await playStored(starter)
        #expect(starter.started.first?.0 == .wined3d)
        #expect(try GameLibrary.load(from: paths.library)[game.id]?.exeStamp != nil)
    }

    @Test func forgettingKeepsWhatThePlayerChose() {
        var record = game
        record.backend = .dxmt
        record.window = Self.window
        record.chromium = .inProcessGPU
        record.chosenBackend = .wined3d
        record.arguments = "-windowed"
        #expect(record.hasLaunchSettings)
        record.forgetLaunchSettings()
        #expect(!record.hasLaunchSettings)
        #expect(record.chosenBackend == .wined3d)
        #expect(record.arguments == "-windowed")
    }
}
