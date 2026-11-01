import Foundation

/// The steps of adding D3DMetal (`D3DMetal`), as the app's DirectX 12 window walks the player through them. The
/// window moves on by itself as things happen (Apple's page opened, the file showing up in Downloads, the check
/// done), so the player only ever does the one thing the current step shows.
public enum D3DMetalSetup {
    public enum Step: Equatable, Sendable {
        /// What DirectX 12 needs, and the button to Apple's page.
        case start
        /// The player is in the browser; Plaviox waits for the file in Downloads.
        case download
        /// The file is being opened and its signature checked.
        case checking
        /// Signed by Apple: Apple's license, and Agree and Add.
        case license
        case done
    }

    public enum Event: Equatable, Sendable {
        case openedApplePage
        /// A file was found in Downloads or chosen by the player.
        case gotFile
        case checked
        case checkFailed
        case agreed
        case back
    }

    public static func next(_ step: Step, on event: Event) -> Step {
        switch (step, event) {
        case (.start, .openedApplePage): .download
        case (.start, .gotFile), (.download, .gotFile): .checking
        case (.checking, .checked): .license
        // A wrong or damaged file needs another download: back to the browser step, which says what went wrong.
        case (.checking, .checkFailed): .download
        case (.license, .agreed): .done
        case (.download, .back), (.license, .back): .start
        default: step
        }
    }

    /// What is in Downloads, from its file names: the newest image of Apple's "Evaluation environment for Windows
    /// games", and whether the player took the other download from the same page, Game Porting Toolkit, instead.
    public struct Downloads: Equatable, Sendable {
        public var image: String?
        public var portingToolkit: Bool
    }

    public static func downloads(_ names: [String]) -> Downloads {
        let images = names.filter {
            $0.hasPrefix("Evaluation_environment_for_Windows_games") && $0.lowercased().hasSuffix(".dmg")
        }
        let toolkit = names.contains {
            $0.hasPrefix("Game_Porting_Toolkit") && $0.lowercased().hasSuffix(".dmg")
        }
        return Downloads(image: images.max { $0.localizedStandardCompare($1) == .orderedAscending },
                         portingToolkit: toolkit)
    }

    /// Why a file can't be used, in the terms the window explains it.
    public enum Problem: Equatable, Sendable {
        /// Game Porting Toolkit, the red item on Apple's page: tools for porting, no D3DMetal.
        case portingToolkit
        /// Some other image without D3DMetal.
        case notD3DMetal
        case notSignedByApple
        /// Damaged, or still downloading.
        case unreadable
    }

    public static func problem(_ error: D3DMetal.ImportError, image: String) -> Problem {
        switch error {
        case .notD3DMetal: image.hasPrefix("Game_Porting_Toolkit") ? .portingToolkit : .notD3DMetal
        case .notSignedByApple: .notSignedByApple
        case .cantAttach: .unreadable
        }
    }
}
