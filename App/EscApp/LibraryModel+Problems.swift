import AppKit
import EscAppKit
import Foundation
import UniformTypeIdentifiers

/// Honest messages (Problems.dc.html): what won't run and why, and what can be done about it.
extension LibraryModel {
    struct Problem: Identifiable {
        enum Kind {
            /// A Windows 3.x program: Wine on a Mac can't run 16-bit code.
            case sixteenBit
            /// A DOS program: DOSBox runs those, not Wine.
            case dos
            /// Called .exe, but no Windows program inside.
            case notWindows
            /// The game asked for its CD, with what its message box said.
            case needsDisc(GameID, message: String?)
        }

        let id = UUID()
        var kind: Kind
    }

    /// What keeps a file from running at all, read before it joins the library.
    static func problem(with exe: URL) -> Problem.Kind? {
        guard let info = try? ExecutableInfo.read(exe) else { return .notWindows }
        switch info.format {
        case .win16: return .sixteenBit
        case .dos: return .dos
        case .pe32, .pe64: return nil
        }
    }

    /// "Choose Disc Image…": the image becomes the game's disc, and the game starts again with it in drive D:.
    func chooseDisc(for id: GameID) {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose the game's disc image")
        panel.allowedContentTypes = DiscImage.extensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        problem = nil
        Task {
            // The game may still be waiting with its "insert the CD" box: it ends first.
            if let session = sessions[id] { await session.stop() }
            await launchTasks[id]?.value
            update(id) { $0.disc = url.path(percentEncoded: false) }
            if let game = game(id) { play(game) }
        }
    }
}
