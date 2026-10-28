#if DEBUG
import AppKit
import EscAppKit
import SwiftUI

/// Debug builds only: `EscApp -snapshotDirectX12 <folder>` draws every step of the DirectX 12 window, its Settings
/// card and the "needs DirectX 12" message into PNGs in the app's language (`-AppleLanguages (ru)`), prints each
/// one's size and quits. The window's step once grew taller than the window and its buttons were cut off; this
/// shows every language without clicking through the app. Run it with `ESCAPP_HOME` set to a scratch folder.
@MainActor
enum DirectX12Snapshots {
    static func runIfAsked() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-snapshotDirectX12"), index + 1 < arguments.count else { return }
        let folder = URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let model = DirectX12Model()
        let library = LibraryModel()
        let downloads = URL(filePath: "/Users/player/Downloads", directoryHint: .isDirectory)
        let image = downloads.appending(path: "Evaluation_environment_for_Windows_games_4.0_beta_3.dmg")
        let shots = [
            Shot(name: "1-start", step: .start),
            Shot(name: "1-start-found", step: .start, found: image),
            Shot(name: "2-download", step: .download),
            Shot(name: "2-download-problem", step: .download, problem: DirectX12Model.message(for: .portingToolkit)),
            Shot(name: "3-checking", step: .checking),
            Shot(name: "4-license", step: .license),
            Shot(name: "5-done", step: .done),
        ]
        for shot in shots {
            model.showForSnapshot(shot.step, problem: shot.problem, found: shot.found)
            save(DirectX12Window(model: model, library: library), "\(language)-window-\(shot.name)", in: folder)
        }
        model.showForSnapshot(.start, problem: nil, found: nil)
        save(DirectX12Card(model: model, components: ComponentsModel()).frame(width: 640).padding(24)
                .background(Color.windowBackground), "\(language)-settings", in: folder)
        save(ProblemSheet(problem: .init(kind: .needsDirectX12), library: library), "\(language)-problem", in: folder)
        exit(0)
    }

    private struct Shot {
        var name: String
        var step: D3DMetalSetup.Step
        var problem: String?
        var found: URL?
    }

    private static func save(_ view: some View, _ name: String, in folder: URL) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("SNAPSHOT \(name) failed")
            return
        }
        try? png.write(to: folder.appending(path: "\(name).png"))
        print("SNAPSHOT \(name) \(Int(image.size.width))x\(Int(image.size.height))")
    }
}
#endif
