@testable import EscAppKit
import Testing

@Suite struct D3DMetalSetupTests {
    typealias Setup = D3DMetalSetup

    /// The way most players go: open Apple's page, the file shows up, it checks out, they agree.
    @Test func theUsualWayThrough() {
        var step = Setup.Step.start
        for event: Setup.Event in [.openedApplePage, .gotFile, .checked, .agreed] {
            step = Setup.next(step, on: event)
        }
        #expect(step == .done)
    }

    /// A player who has the file already skips the browser.
    @Test func aFileAtTheStartGoesStraightToTheCheck() {
        #expect(Setup.next(.start, on: .gotFile) == .checking)
    }

    /// A wrong or damaged file needs another download, so the browser step comes back with the reason.
    @Test func aFailedCheckGoesBackToTheDownload() {
        #expect(Setup.next(.checking, on: .checkFailed) == .download)
    }

    @Test func backReturnsToTheStart() {
        #expect(Setup.next(.download, on: .back) == .start)
        #expect(Setup.next(.license, on: .back) == .start)
    }

    @Test func eventsOutOfPlaceChangeNothing() {
        #expect(Setup.next(.done, on: .gotFile) == .done)
        #expect(Setup.next(.checking, on: .back) == .checking)
        #expect(Setup.next(.start, on: .agreed) == .start)
    }

    @Test func findsTheNewestImageInDownloads() {
        let names = ["game.zip", "Evaluation_environment_for_Windows_games_3.0.dmg",
                     "Evaluation_environment_for_Windows_games_4.0_beta_3.dmg", "Evaluation_environment.txt"]
        #expect(Setup.downloads(names) == .init(image: "Evaluation_environment_for_Windows_games_4.0_beta_3.dmg",
                                                portingToolkit: false))
    }

    /// Both downloads sit on the same Apple page; the red one has no D3DMetal.
    @Test func noticesGamePortingToolkitInstead() {
        let found = Setup.downloads(["Game_Porting_Toolkit_3.0.dmg"])
        #expect(found.image == nil && found.portingToolkit)
    }

    /// Safari keeps a download in `….dmg.download` until it is complete.
    @Test func ignoresADownloadStillInProgress() {
        #expect(Setup.downloads(["Evaluation_environment_for_Windows_games_3.0.dmg.download"]).image == nil)
    }

    @Test func explainsWhatIsWrongWithAFile() {
        #expect(Setup.problem(.notD3DMetal, image: "Game_Porting_Toolkit_3.0.dmg") == .portingToolkit)
        #expect(Setup.problem(.notD3DMetal, image: "something.dmg") == .notD3DMetal)
        #expect(Setup.problem(.notSignedByApple("libd3dshared.dylib"), image: "x.dmg") == .notSignedByApple)
        #expect(Setup.problem(.cantAttach("x.dmg"), image: "x.dmg") == .unreadable)
    }
}
