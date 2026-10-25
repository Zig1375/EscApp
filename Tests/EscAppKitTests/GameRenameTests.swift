@testable import EscAppKit
import Foundation
import Testing

@Suite struct GameRenameTests {
    private func game(store: Store? = nil) -> GameRecord {
        var game = GameRecord(id: .make(), name: "Diablo II", executable: "/g/d2.exe", folder: "/g", hasMarker: true,
                              addedAt: Date())
        game.store = store
        return game
    }

    @Test func ownGameTakesATrimmedName() {
        var diablo = game()
        let renamed = diablo.rename(to: "  Diablo II: LoD \n")
        #expect(renamed && diablo.name == "Diablo II: LoD")
    }

    @Test func emptyNameIsIgnored() {
        var diablo = game()
        let renamed = diablo.rename(to: "   ")
        #expect(!renamed && diablo.name == "Diablo II")
    }

    @Test func storeGameKeepsItsStoresName() {
        var banished = game(store: .steam)
        #expect(!banished.canRename)
        let renamed = banished.rename(to: "My Town")
        #expect(!renamed && banished.name == "Diablo II")
    }

    @Test func originalNameIsKeptAcrossRenamesAndRestored() {
        var diablo = game()
        diablo.rename(to: "D2")
        diablo.rename(to: "Diablo 2")
        #expect(diablo.name == "Diablo 2" && diablo.originalName == "Diablo II")
        diablo.restoreName()
        #expect(diablo.name == "Diablo II" && diablo.originalName == nil)
    }

    @Test func typingTheOriginalBackForgetsIt() {
        var diablo = game()
        diablo.rename(to: "D2")
        diablo.rename(to: "Diablo II")
        #expect(diablo.originalName == nil)
        diablo.rename(to: "Diablo II")
        #expect(diablo.originalName == nil)
    }
}
