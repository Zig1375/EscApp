@testable import EscAppKit
import Foundation
import Synchronization
import Testing

/// The warm-up's bookkeeping with scripted Wine: which bottles stay warm, and what is stopped when.
@Suite struct BottleWarmerTests {
    final class FakeSteps: WarmUpSteps, @unchecked Sendable {
        final class Hold: WineHold, @unchecked Sendable {
            let name: String
            let log: FakeSteps
            init(_ name: String, log: FakeSteps) {
                self.name = name
                self.log = log
            }

            func release() { log.note("release \(name)") }
        }

        private let state = Mutex<(calls: [String], gates: [String: CheckedContinuation<Void, Never>])>(([], [:]))
        /// Games whose boot waits until `open` is called for them.
        let gated: Set<String>
        let withoutBottle: Set<String>

        init(gated: Set<String> = [], withoutBottle: Set<String> = []) {
            self.gated = gated
            self.withoutBottle = withoutBottle
        }

        var calls: [String] { state.withLock { $0.calls } }
        func note(_ call: String) { state.withLock { $0.calls.append(call) } }

        func canWarm(_ game: GameRecord, runtime: RuntimeManifest.Runtime) -> Bool {
            !withoutBottle.contains(game.name)
        }

        func boot(_ game: GameRecord, runtime: RuntimeManifest.Runtime) async -> WarmWine? {
            note("boot \(game.name)")
            if gated.contains(game.name) {
                await withCheckedContinuation { continuation in
                    state.withLock { $0.gates[game.name] = continuation }
                }
            }
            return WarmWine(wine: Wine(root: URL(filePath: "/fake")), environment: ["GAME": game.name])
        }

        func hold(_ wine: WarmWine) -> (any WineHold)? {
            let name = wine.environment["GAME"] ?? "?"
            note("hold \(name)")
            return Hold(name, log: self)
        }

        func shutDown(_ wine: WarmWine) async { note("shut down \(wine.environment["GAME"] ?? "?")") }

        /// Lets a gated boot finish, once it is waiting.
        func open(_ name: String) async {
            while true {
                if let gate = state.withLock({ $0.gates.removeValue(forKey: name) }) {
                    gate.resume()
                    return
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }

        func waitForCall(_ call: String) async {
            while !calls.contains(call) { try? await Task.sleep(for: .milliseconds(2)) }
        }
    }

    let runtime = RuntimeManifest.Runtime(id: "test", minApp: Version("0.1")!, minMacOS: Version("15")!,
                                          components: [])
    let paths = AppPaths(root: URL(filePath: "/nonexistent"), games: URL(filePath: "/nonexistent"))

    func game(_ name: String) -> GameRecord {
        GameRecord(id: GameID.make(), name: name, executable: "/\(name).exe", folder: "/", hasMarker: true,
                   addedAt: Date())
    }

    func warmer(_ steps: FakeSteps, memory: UInt64 = 32 << 30) -> BottleWarmer {
        BottleWarmer(paths: paths, steps: steps, memory: memory)
    }

    @Test func aThirdBottleCoolsTheOldest() async {
        let steps = FakeSteps()
        let warmer = warmer(steps)
        let (gameA, gameB, gameC) = (game("A"), game("B"), game("C"))
        await warmer.warm(gameA, runtime: runtime)
        await warmer.warm(gameB, runtime: runtime)
        await warmer.warm(gameC, runtime: runtime)
        #expect(await warmer.warmGames == [gameB.id, gameC.id])
        #expect(steps.calls.contains("release A") && steps.calls.contains("shut down A"))
    }

    @Test func warmingAgainOnlyMovesItUp() async {
        let steps = FakeSteps()
        let warmer = warmer(steps)
        let (gameA, gameB) = (game("A"), game("B"))
        await warmer.warm(gameA, runtime: runtime)
        await warmer.warm(gameB, runtime: runtime)
        await warmer.warm(gameA, runtime: runtime)
        #expect(await warmer.warmGames == [gameB.id, gameA.id])
        #expect(steps.calls.filter { $0 == "boot A" }.count == 1)
    }

    @Test func smallMacsAndGamesWithoutABottleArentWarmed() async {
        let steps = FakeSteps(withoutBottle: ["New"])
        await warmer(steps, memory: 8 << 30).warm(game("A"), runtime: runtime)
        await warmer(steps, memory: 16 << 30 - 1).warm(game("A"), runtime: runtime)
        await warmer(steps).warm(game("New"), runtime: runtime)
        #expect(steps.calls.isEmpty)
        await warmer(steps, memory: 16 << 30).warm(game("A"), runtime: runtime)
        #expect(steps.calls == ["boot A", "hold A"])
    }

    @Test func releasingHandsTheRunningWineToTheGame() async {
        let steps = FakeSteps()
        let warmer = warmer(steps)
        let gameA = game("A")
        await warmer.warm(gameA, runtime: runtime)
        await warmer.release(gameA.id)
        #expect(steps.calls == ["boot A", "hold A", "release A"])
        #expect(await warmer.warmGames.isEmpty)
    }

    @Test func coolingStopsWineAtOnce() async {
        let steps = FakeSteps()
        let warmer = warmer(steps)
        let (gameA, gameB) = (game("A"), game("B"))
        await warmer.warm(gameA, runtime: runtime)
        await warmer.warm(gameB, runtime: runtime)
        await warmer.coolAll(except: gameB.id)
        #expect(await warmer.warmGames == [gameB.id])
        #expect(steps.calls.suffix(2) == ["release A", "shut down A"])
    }

    @Test func coolingWhileWarmingStopsWhatStarted() async {
        let steps = FakeSteps(gated: ["A"])
        let warmer = warmer(steps)
        let gameA = game("A")
        let runtime = runtime
        let warming = Task { await warmer.warm(gameA, runtime: runtime) }
        await steps.waitForCall("boot A")
        await warmer.cool(gameA.id)
        await steps.open("A")
        await warming.value
        #expect(steps.calls == ["boot A", "shut down A"])
        #expect(await warmer.warmGames.isEmpty)
    }

    @Test func launchingWhileWarmingLeavesWineToTheGame() async {
        let steps = FakeSteps(gated: ["A"])
        let warmer = warmer(steps)
        let gameA = game("A")
        let runtime = runtime
        let warming = Task { await warmer.warm(gameA, runtime: runtime) }
        await steps.waitForCall("boot A")
        await warmer.release(gameA.id)
        await steps.open("A")
        await warming.value
        // Neither held (the bottle must go idle after the game) nor shut down (the game is starting in it).
        #expect(steps.calls == ["boot A"])
    }
}

@Suite struct WarmPolicyTests {
    @Test func warmsOnlyInFrontWithNoGameAndEnoughMemory() {
        let big: UInt64 = 16 << 30
        #expect(WarmPolicy.mayWarm(ready: true, appActive: true, gamesRunning: false, memory: big))
        #expect(!WarmPolicy.mayWarm(ready: false, appActive: true, gamesRunning: false, memory: big))
        #expect(!WarmPolicy.mayWarm(ready: true, appActive: false, gamesRunning: false, memory: big))
        #expect(!WarmPolicy.mayWarm(ready: true, appActive: true, gamesRunning: true, memory: big))
        #expect(!WarmPolicy.mayWarm(ready: true, appActive: true, gamesRunning: false, memory: 8 << 30))
    }

    @Test func picksTheLastPlayedGame() {
        func game(_ name: String, played: TimeInterval?) -> GameRecord {
            GameRecord(id: GameID.make(), name: name, executable: "/", folder: "/", hasMarker: true,
                       addedAt: Date(), lastPlayed: played.map { Date(timeIntervalSince1970: $0) })
        }
        let games = [game("old", played: 100), game("never", played: nil), game("recent", played: 200)]
        #expect(WarmPolicy.lastPlayed(games)?.name == "recent")
        #expect(WarmPolicy.lastPlayed([game("never", played: nil)]) == nil)
    }

    @Test func coolsAFewSecondsAfterFocusIsLost() {
        #expect(WarmPolicy.coolAfterFocusLoss == .seconds(5))
    }
}
