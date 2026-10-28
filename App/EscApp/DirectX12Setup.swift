import AppKit
import EscAppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Adding D3DMetal for DirectX 12 games (`D3DMetal`): the player downloads Apple's disk image themselves, EscApp
/// checks it and, once they accept Apple's license, copies D3DMetal from it. EscApp never ships it.
@MainActor @Observable
final class DirectX12Model {
    enum Stage: Equatable {
        case idle
        case checking
        /// Signed by Apple and copied aside, waiting for the player to accept Apple's license.
        case review(D3DMetalCandidate, license: AttributedString)
    }

    /// Where Apple lists the download. A search, so it still lands right when Apple renames the page.
    static let applePage = URL(
        string: "https://developer.apple.com/download/all/?q=Evaluation%20environment%20for%20Windows%20games")!

    private(set) var installed: D3DMetal.Installed?
    private(set) var stage = Stage.idle
    private(set) var error: String?
    /// An image from Apple already in Downloads, offered so the player doesn't have to look for it.
    private(set) var found: URL?
    let paths: AppPaths

    init(paths: AppPaths = .standard()) {
        self.paths = paths
        reload()
    }

    func reload() {
        installed = D3DMetal.installed(paths: paths)?.info
        found = installed == nil ? Self.downloadedImage() : nil
    }

    func openApplePage() {
        NSWorkspace.shared.open(Self.applePage)
    }

    /// The same steps on EscApp's site (`site/directx12.html`), in the app's language.
    func openGuide() {
        let languages = ["de", "es", "fr", "it", "ja", "ko", "ru", "zh-Hans"]
        let language = Bundle.main.preferredLocalizations.first.flatMap { languages.contains($0) ? $0 + "/" : nil }
        if let url = URL(string: "https://zig1375.github.io/EscApp/\(language ?? "")directx12.html") {
            NSWorkspace.shared.open(url)
        }
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
        guard stage == .idle else { return }
        error = nil
        stage = .checking
        do {
            let candidate = try await D3DMetal.prepare(image: image, paths: paths)
            let license = (try? NSAttributedString(url: candidate.license, options: [:], documentAttributes: nil))
                .map { AttributedString($0.string) } ?? AttributedString()
            stage = .review(candidate, license: license)
        } catch {
            stage = .idle
            self.error = Self.message(for: error)
        }
    }

    func agree() {
        guard case let .review(candidate, _) = stage else { return }
        do {
            try D3DMetal.install(candidate, paths: paths)
        } catch {
            D3DMetal.discard(candidate)
            self.error = String(localized: "Couldn't add D3DMetal: \(error.localizedDescription)")
        }
        stage = .idle
        reload()
    }

    func cancel() {
        if case let .review(candidate, _) = stage { D3DMetal.discard(candidate) }
        stage = .idle
    }

    func remove() {
        do { try D3DMetal.remove(paths: paths) } catch {
            self.error = String(localized: "Couldn't remove D3DMetal: \(error.localizedDescription)")
        }
        reload()
    }

    /// The newest `Evaluation_environment_for_Windows_games_*.dmg` in Downloads.
    static func downloadedImage() -> URL? {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
              let names = try? FileManager.default.contentsOfDirectory(atPath: downloads.path) else { return nil }
        return names.filter { $0.hasPrefix("Evaluation_environment_for_Windows_games") && $0.hasSuffix(".dmg") }
            .max { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { downloads.appending(path: $0) }
    }

    static func message(for error: any Error) -> String {
        switch error as? D3DMetal.ImportError {
        case .notD3DMetal?:
            String(localized: """
                This file doesn't contain D3DMetal. Download “Evaluation environment for Windows games” from \
                Apple's page, not “Game Porting Toolkit”.
                """)
        case .notSignedByApple?:
            String(localized: """
                This file isn't signed by Apple. It may be damaged: download it again from Apple's page.
                """)
        case .cantAttach?:
            String(localized: "This file can't be opened. It may be damaged or still downloading.")
        case nil:
            error.localizedDescription
        }
    }
}

/// Settings › DirectX 12: what it is, and the three steps to add it.
struct DirectX12Card: View {
    let model: DirectX12Model
    let components: ComponentsModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                Text("""
                    DirectX 12 games run on D3DMetal, Apple's own translation of DirectX 12 to Metal. Apple doesn't \
                    allow EscApp to include it, but you can download it from Apple yourself, for free. It takes a \
                    couple of minutes, once.
                    """)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Step-by-step guide") { model.openGuide() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.brand)
                if let installed = model.installed {
                    ready(installed)
                } else {
                    steps
                }
                if let error = model.error {
                    Text(error)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.brand)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !runtimeReady {
                    Note(text: """
                        DirectX 12 games also need the newest EscApp components. Update them in Components.
                        """)
                }
            }
            if case let .review(candidate, license) = model.stage {
                review(candidate, license: license)
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
            Button("Replace…") { model.chooseFile() }
                .buttonStyle(CompactButtonStyle())
            Button("Remove", role: .destructive) { model.remove() }
                .buttonStyle(CompactButtonStyle())
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 14) {
            step(1, title: "Download it from Apple", text: """
                Sign in with your Apple Account; a free one is enough, no paid membership. The first time, Apple asks \
                you to accept its developer agreement, which is free too. Then download “Evaluation environment for \
                Windows games 3.0” (a .dmg file). You don't need to open it.
                """) {
                Button("Open Apple's Download Page") { model.openApplePage() }
                    .buttonStyle(CompactButtonStyle(kind: .primary))
            }
            step(2, title: "Show EscApp the file", text: """
                Choose the downloaded file, or drop it here. EscApp opens it, finds D3DMetal and checks that it's \
                signed by Apple. Nothing is added yet.
                """) {
                HStack(spacing: 12) {
                    if let found = model.found {
                        Button("Use \(found.lastPathComponent)") { Task { await model.check(found) } }
                            .buttonStyle(CompactButtonStyle(kind: .primary))
                    }
                    Button("Choose File…") { model.chooseFile() }
                        .buttonStyle(CompactButtonStyle(kind: model.found == nil ? .primary : .plain))
                    if model.stage == .checking {
                        ProgressView().controlSize(.small)
                        Text("Checking…").font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                    }
                }
            }
            step(3, title: "Accept Apple's license", text: """
                EscApp shows you the license from your download. When you agree, it adds D3DMetal and DirectX 12 \
                games start like any other.
                """) { EmptyView() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dropTargeted ? Color.brand.opacity(0.08) : .clear, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(dropTargeted ? Color.brand : Color.cardBorder,
                              style: StrokeStyle(lineWidth: 1, dash: [5]))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let image = urls.first(where: { $0.pathExtension.lowercased() == "dmg" }) else { return false }
            Task { await model.check(image) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func step(_ number: Int, title: LocalizedStringKey, text: LocalizedStringKey,
                      @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(number))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.brand, in: .circle)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Note(text: text)
                action()
            }
        }
    }

    private func review(_ candidate: D3DMetalCandidate, license: AttributedString) -> some View {
        SettingsCard {
            Text("D3DMetal \(candidate.version), signed by Apple").font(.system(size: 14, weight: .semibold))
            Note(text: "Apple's license for it, from your download:")
            ScrollView {
                Text(license)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 220)
            .background(Color.windowBackground, in: .rect(cornerRadius: 8))
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { model.cancel() }
                    .buttonStyle(CompactButtonStyle())
                Button("Agree and Add") { model.agree() }
                    .buttonStyle(CompactButtonStyle(kind: .primary))
            }
        }
    }
}
