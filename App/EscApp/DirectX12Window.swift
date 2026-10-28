import EscAppKit
import SwiftUI

/// The DirectX 12 window: adding D3DMetal one step at a time (`D3DMetalSetup`). Each step shows one thing to do,
/// and the window moves on by itself as it happens: Apple's page opened, the file in Downloads, the check done.
struct DirectX12Window: View {
    static let id = "directx12"
    let model: DirectX12Model
    let library: LibraryModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            progress
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(28)
        .frame(width: 640, height: 600)
        .background(Color.windowBackground)
        .background(dropTargeted ? Color.brand.opacity(0.06) : .clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let image = urls.first(where: { $0.pathExtension.lowercased() == "dmg" }) else { return false }
            Task { await model.check(image) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .onAppear { model.opened() }
        // The player downloads in the browser and comes back: the file in Downloads is picked up without a click.
        .task {
            while !Task.isCancelled {
                model.reload()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch model.step {
        case .start: start
        case .download: download
        case .checking: checking
        case .license: license
        case .done: done
        }
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Add DirectX 12")
            Text("""
                Some games need DirectX 12. On a Mac it runs on D3DMetal, Apple's own component. Apple doesn't let \
                EscApp include it, so you download it from Apple yourself: it's free and takes a couple of \
                minutes, once.
                """)
                .fixedSize(horizontal: false, vertical: true)
            Text("You need an Apple Account (Apple ID). A free one is enough, no paid developer membership.")
                .font(.system(size: 13))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack(spacing: 12) {
                if let found = model.found {
                    Button("Use \(found.lastPathComponent)") { Task { await model.check(found) } }
                        .buttonStyle(BrandButtonStyle(height: 36, radius: 9))
                } else {
                    Button("I Already Have the File…") { model.chooseFile() }
                        .buttonStyle(BrandButtonStyle(height: 36, radius: 9))
                }
                Spacer()
                Button("Open Apple's Download Page") { model.openApplePage() }
                    .buttonStyle(BrandButtonStyle(kind: .primary, height: 36, radius: 9))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var download: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("In your browser")
            if let problem = model.problem {
                Callout(tone: .error) { Text(problem) }
            }
            ApplePageSketch()
            VStack(alignment: .leading, spacing: 6) {
                point(1, """
                    Sign in with your Apple Account. The first time, agree to Apple's developer terms; it's free.
                    """)
                point(2, """
                    Find **Evaluation environment for Windows games** with the blue icon, click **View Details**, \
                    then the **.dmg** file.
                    """)
                point(3, "Don't open the file. EscApp sees it in Downloads and goes on by itself.")
            }
            Spacer()
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Waiting for the file in Downloads…")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondaryText)
                Spacer()
            }
            HStack(spacing: 12) {
                Button("Back") { model.back() }
                    .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
                Spacer()
                Button("Open Apple's Page Again") { model.openApplePage() }
                    .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
                Button("The File Is Somewhere Else…") { model.chooseFile() }
                    .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
            }
        }
    }

    private var checking: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Checking the file from Apple…").font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var license: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Accept Apple's license")
            if let candidate = model.candidate {
                Text("D3DMetal \(candidate.version), signed by Apple")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.okText)
            }
            Text("Apple's license for it, from your download:")
                .font(.system(size: 13))
                .foregroundStyle(Color.secondaryText)
            ScrollView {
                Text(model.license)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color.cardBackground, in: .rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.cardBorder) }
            HStack(spacing: 12) {
                Button("Back") { model.back() }
                    .buttonStyle(BrandButtonStyle(height: 36, radius: 9))
                Spacer()
                Button("Agree and Add") { model.agree() }
                    .buttonStyle(BrandButtonStyle(kind: .primary, height: 36, radius: 9))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var done: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.okText)
                .accessibilityHidden(true)
            Text("DirectX 12 is ready").font(.system(size: 22, weight: .bold))
            Text("DirectX 12 games now start like any other.")
                .foregroundStyle(Color.secondaryText)
            if let installed = model.installed {
                Text("D3DMetal \(installed.version)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
            }
            Spacer()
            HStack(spacing: 12) {
                Spacer()
                if let id = library.directX12Game, let game = library.game(id) {
                    Button("Done") { close() }
                        .buttonStyle(BrandButtonStyle(height: 36, radius: 9))
                    Button("Start \(game.name)") {
                        close()
                        library.play(game)
                    }
                    .buttonStyle(BrandButtonStyle(kind: .primary, height: 36, radius: 9))
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { close() }
                        .buttonStyle(BrandButtonStyle(kind: .primary, height: 36, radius: 9))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Parts

    private func close() {
        library.directX12Game = nil
        dismissWindow(id: Self.id)
    }

    /// Step dots: where the player is out of the four steps they take part in.
    private var progress: some View {
        let order: [D3DMetalSetup.Step] = [.start, .download, .license, .done]
        let current = order.firstIndex(of: model.step == .checking ? .download : model.step) ?? 0
        return HStack(spacing: 6) {
            ForEach(order.indices, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? Color.brand : Color.cardBorder)
                    .frame(width: index == current ? 28 : 14, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Step \(current + 1) of \(order.count)"))
    }

    private func heading(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .bold))
            .accessibilityAddTraits(.isHeader)
    }

    private func point(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(number))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.brand, in: .circle)
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A drawing of the part of Apple's download page that matters: the blue item to take, the red one to leave, and
/// where to click. Drawn by EscApp rather than a picture of Apple's page; Apple's own names stay in English, as the
/// page shows them.
struct ApplePageSketch: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.cardBorder).frame(width: 8, height: 8) }
                Text(verbatim: "developer.apple.com/download")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
                    .padding(.leading, 6)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                item(color: .blue, name: "Evaluation environment for Windows games 3.0", take: true)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(verbatim: "View Details ⌄").font(.system(size: 12, weight: .semibold))
                        marker("1")
                    }
                    HStack(spacing: 6) {
                        Text(verbatim: "Evaluation_environment_for_Windows_games_3.0.dmg")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.brand)
                            .underline()
                        marker("2")
                    }
                }
                .padding(.leading, 40)
                Divider()
                item(color: .red, name: "Game Porting Toolkit 3.0", take: false)
            }
            .padding(12)
        }
        .background(Color.cardBackground, in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.cardBorder) }
        .accessibilityElement(children: .combine)
    }

    private func item(color: Color, name: String, take: Bool) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.gradient)
                .frame(width: 28, height: 28)
            Text(verbatim: name)
                .font(.system(size: 13, weight: .semibold))
                .strikethrough(!take)
                .foregroundStyle(take ? Color.primary : Color.secondaryText)
            Spacer(minLength: 8)
            Label(take ? "This one" : "Not this one", systemImage: take ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(take ? Color.okText : Color.secondaryText)
        }
        .padding(6)
        .overlay {
            if take {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.okText, lineWidth: 2)
            }
        }
    }

    private func marker(_ number: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.left")
            Text("Click")
            Text(verbatim: number)
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.brand, in: .capsule)
    }
}
