import Foundation
@testable import MagicKettleKit
import Synchronization
import Testing

/// When a launch opens the first-launch screen (`AutoLaunch.isTuning`), and when it doesn't.
extension AutoLaunchTests {
    @Test func aFirstLaunchOnAutoSaysItIsLookingForSettingsBeforeAnythingElse() async throws {
        let starter = try FakeStarter([.dxvk: .crashes(), .dxmt: .works], logs: logs())
        let events = Mutex<[String]>([])
        _ = try await play(starter) { event in
            let name = switch event {
            case let .tuning(order): "tuning " + order.map(\.rawValue).joined(separator: ",")
            case .checking: "checking"
            case .started: "started"
            default: ""
            }
            if !name.isEmpty { events.withLock { if $0.last != name { $0.append(name) } } }
        }
        let seen = events.withLock { $0 }
        #expect(seen.first == "tuning dxvk,dxmt,wined3d")
        #expect(seen.contains("checking"))

        // Once a backend is known to work, the next launch is an ordinary one.
        var next = try #require(GameLibrary.load(from: paths.library)[game.id])
        #expect(!AutoLaunch.isTuning(next, order: [.dxmt, .dxvk], retrying: true))
        next.backend = nil
        #expect(AutoLaunch.isTuning(next, order: [.dxvk, .dxmt], retrying: true))
        #expect(!AutoLaunch.isTuning(next, order: [.dxvk], retrying: true))
        #expect(!AutoLaunch.isTuning(next, order: [.dxvk, .dxmt], retrying: false))
        next.chosenBackend = .dxvk
        #expect(!AutoLaunch.isTuning(next, order: [.dxvk, .dxmt], retrying: true))
    }

    @Test func aSearchThatFoundNothingSearchesAgainNextTime() async throws {
        // Nothing worked: no backend is kept, so the next launch opens the first-launch screen again rather than
        // starting the game on one that failed.
        let starter = try FakeStarter([.dxvk: .crashes(), .dxmt: .crashes(), .wined3d: .crashes()], logs: logs())
        let result = try await play(starter)
        #expect(result.working == nil)
        let next = try #require(GameLibrary.load(from: paths.library)[game.id])
        #expect(next.backend == nil && next.chosenBackend == nil)
        #expect(next.launches == 1)
        #expect(AutoLaunch.isTuning(next, order: [.dxvk, .dxmt, .wined3d], retrying: true))
    }
}
