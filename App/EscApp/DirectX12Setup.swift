import AppKit
import EscAppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Adding D3DMetal for DirectX 12 games (`D3DMetal`): the player downloads Apple's disk image themselves, EscApp
/// checks it and, once they accept Apple's license, copies D3DMetal from it. EscApp never ships it. The DirectX 12
/// window (`DirectX12Window`) walks through it one step at a time (`D3DMetalSetup`); Settings shows what is there.
@MainActor @Observable
final class DirectX12Model {
    /// Where Apple lists the download. A search, so it still lands right when Apple renames the page; signed out,
    /// Apple's sign-in comes back to it afterwards.
    static let applePage = URL(
        string: "https://developer.apple.com/download/all/?q=Evaluation%20environment%20for%20Windows%20games")!

    private(set) var installed: D3DMetal.Installed?
    private(set) var step = D3DMetalSetup.Step.start
    /// Signed by Apple and copied aside, waiting for the player to accept Apple's license.
    private(set) var candidate: D3DMetalCandidate?
    private(set) var license = AttributedString()
    /// Why the last file couldn't be used, shown on the download step.
    private(set) var problem: String?
    /// An image from Apple already in Downloads, offered on the first step.
    private(set) var found: URL?
    /// Files that failed the check, so watching Downloads doesn't try them again and again.
    private var rejected: Set<String> = []
    /// Set by Replace…, so the window starts over instead of saying D3DMetal is there.
    private var replacing = false
    let paths: AppPaths

    init(paths: AppPaths = .standard()) {
        self.paths = paths
        reload()
    }

    /// Reads what is installed and what is in Downloads. On the download step a new image is checked right away:
    /// the player comes back from the browser and the window goes on by itself.
    func reload() {
        installed = D3DMetal.installed(paths: paths)?.info
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []
        let seen = D3DMetalSetup.downloads(names)
        found = seen.image.flatMap { rejected.contains($0) ? nil : downloads.appending(path: $0) }
        if step == .download, let found {
            Task { await check(found) }
        } else if step == .download, seen.image == nil, seen.portingToolkit, problem == nil {
            problem = Self.message(for: .portingToolkit)
        }
    }

    /// The first step again, for adding D3DMetal over one that is there (Replace…).
    func restart() {
        discardCandidate()
        problem = nil
        step = .start
        replacing = installed != nil
    }

    /// Where the window opens: the end, when D3DMetal is there and the player didn't ask to replace it.
    func opened() {
        reload()
        if installed != nil, step == .start, !replacing { step = .done }
    }

    func openApplePage() {
        NSWorkspace.shared.open(Self.applePage)
        step = D3DMetalSetup.next(step, on: .openedApplePage)
    }

    func back() {
        discardCandidate()
        step = D3DMetalSetup.next(step, on: .back)
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dmg") ?? .diskImage]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = String(localized: "Choose the disk image you downloaded from Apple.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await check(url) }
    }

    func check(_ image: URL) async {
        guard step == .start || step == .download else { return }
        problem = nil
        step = D3DMetalSetup.next(step, on: .gotFile)
        do {
            let candidate = try await D3DMetal.prepare(image: image, paths: paths)
            license = (try? NSAttributedString(url: candidate.license, options: [:], documentAttributes: nil))
                .map { AttributedString($0.string) } ?? AttributedString()
            self.candidate = candidate
            step = D3DMetalSetup.next(step, on: .checked)
        } catch {
            rejected.insert(image.lastPathComponent)
            found = nil
            problem = (error as? D3DMetal.ImportError)
                .map { Self.message(for: D3DMetalSetup.problem($0, image: image.lastPathComponent)) }
                ?? error.localizedDescription
            step = D3DMetalSetup.next(step, on: .checkFailed)
        }
    }

    func agree() {
        guard let candidate else { return }
        do {
            try D3DMetal.install(candidate, paths: paths)
            self.candidate = nil
            replacing = false
            step = D3DMetalSetup.next(step, on: .agreed)
        } catch {
            discardCandidate()
            problem = String(localized: "Couldn't add D3DMetal: \(error.localizedDescription)")
            step = .download
        }
        reload()
    }

    func remove() {
        do { try D3DMetal.remove(paths: paths) } catch {
            problem = String(localized: "Couldn't remove D3DMetal: \(error.localizedDescription)")
        }
        restart()
        reload()
    }

    #if DEBUG
    /// For `DirectX12Snapshots`: a step as it would look, with a sample of Apple's license.
    func showForSnapshot(_ step: D3DMetalSetup.Step, problem: String?, found: URL?) {
        self.step = step
        self.problem = problem
        self.found = found
        license = AttributedString(String(repeating: "Apple Inc. Software License Agreement for Game Porting Toolkit. ",
                                          count: 30))
    }
    #endif

    private func discardCandidate() {
        if let candidate { D3DMetal.discard(candidate) }
        candidate = nil
    }

    static func message(for problem: D3DMetalSetup.Problem) -> String {
        switch problem {
        case .portingToolkit:
            String(localized: """
                This is Game Porting Toolkit, a different download from the same page. Download the one with the \
                blue icon: Evaluation environment for Windows games.
                """)
        case .notD3DMetal:
            String(localized: """
                This file doesn't contain D3DMetal. Download “Evaluation environment for Windows games” from \
                Apple's page, not “Game Porting Toolkit”.
                """)
        case .notSignedByApple:
            String(localized: """
                This file isn't signed by Apple. It may be damaged: download it again from Apple's page.
                """)
        case .unreadable:
            String(localized: "This file can't be opened. It may be damaged or still downloading.")
        }
    }
}

/// Settings › DirectX 12: what it is, whether it is there, and the way to add, replace or remove it. Adding happens
/// in the DirectX 12 window, one step at a time.
struct DirectX12Card: View {
    let model: DirectX12Model
    let components: ComponentsModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                Text("""
                    DirectX 12 games run on D3DMetal, Apple's own translation of DirectX 12 to Metal. Apple doesn't \
                    allow EscApp to include it, but you can download it from Apple yourself, for free. It takes a \
                    couple of minutes, once.
                    """)
                    .fixedSize(horizontal: false, vertical: true)
                if let installed = model.installed {
                    ready(installed)
                } else {
                    HStack(spacing: 12) {
                        Text("Not added yet").foregroundStyle(Color.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Set Up DirectX 12…") {
                            model.restart()
                            openWindow(id: DirectX12Window.id)
                        }
                        .buttonStyle(CompactButtonStyle(kind: .primary))
                    }
                }
                if !runtimeReady {
                    Note(text: """
                        DirectX 12 games also need the newest EscApp components. Update them in Components.
                        """)
                }
            }
            SettingsCard {
                Text("About Apple's license").font(.system(size: 14, weight: .semibold))
                Note(text: """
                    D3DMetal is Apple's software. You accept Apple's license when you download it, and your use of it \
                    is between you and Apple: Apple gives it out for developing, testing and evaluating games. \
                    EscApp doesn't include, sell or change it; it copies D3DMetal from your download after checking \
                    Apple's signature and shows you Apple's license first. If you're unsure whether the license fits \
                    how you use it, don't add it.
                    """)
            }
        }
        .onAppear { model.reload() }
    }

    private var runtimeReady: Bool {
        guard let current = components.catalog?.current else { return true }
        return BackendTree.supportsD3DMetal(runtimeFolder: components.paths.runtime(current.id))
    }

    private func ready(_ installed: D3DMetal.Installed) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("D3DMetal \(installed.version)")
                Text("DirectX 12 games start with it on their own.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.okText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Replace…") {
                model.restart()
                openWindow(id: DirectX12Window.id)
            }
            .buttonStyle(CompactButtonStyle())
            Button("Remove", role: .destructive) { model.remove() }
                .buttonStyle(CompactButtonStyle())
        }
    }
}
