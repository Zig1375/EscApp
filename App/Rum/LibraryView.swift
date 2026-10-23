import RumKit
import SwiftUI
import UniformTypeIdentifiers

/// The main window. Until launching lands (M3) the library is always empty, so this is the empty state.
struct LibraryView: View {
    let components: ComponentsModel
    @State private var droppedFile: String?
    @State private var isTargeted = false

    var body: some View {
        EmptyLibraryView()
            // An inset, not an overlay, so the banner pushes the content down instead of covering it.
            .safeAreaInset(edge: .top, spacing: 0) {
                if components.catalog?.updateAvailable == true {
                    UpdateBanner(components: components)
                        .padding(.top, 14)
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.rum, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let name = url?.lastPathComponent else { return }
                    Task { @MainActor in droppedFile = name }
                }
                return true
            }
            .alert("Launching games is coming next", isPresented: .constant(droppedFile != nil)) {
                Button("OK") { droppedFile = nil }
            } message: {
                Text("""
                    Rum got “\(droppedFile ?? "")”, but this early version can't start games yet. \
                    Installing components already works; running games comes in the next milestone.
                    """)
            }
            .animation(.default, value: components.catalog?.updateAvailable)
            .navigationTitle("Rum")
    }
}

private struct UpdateBanner: View {
    let components: ComponentsModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.rum)
            VStack(alignment: .leading, spacing: 1) {
                Text("Component update available").fontWeight(.semibold)
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            SettingsLink { Text("Details") }
            Button("Update") { Task { await components.installUpdate() } }
                .buttonStyle(.borderedProminent)
                .tint(.rum)
                .disabled(components.updating != nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 620)
        .background(.regularMaterial, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)) }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private var summary: String {
        if let progress = components.updating { return progress.label }
        guard case let .updateAvailable(current, newest)? = components.catalog?.status else { return "" }
        return RuntimeCatalog.changes(from: current, to: newest)
            .compactMap { change in change.newVersion.map { "\(change.kind.title) \($0)" } }
            .formatted(.list(type: .and))
    }
}

private struct EmptyLibraryView: View {
    var body: some View {
        ZStack {
            WarmBackground()
            VStack(spacing: 32) {
                RumHero()

                VStack(spacing: 10) {
                    Text("Your games will appear here")
                        .font(.largeTitle.weight(.bold))
                    Text("Rum runs Windows games on this Mac. Just open a game, and Rum takes care of the rest.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 480)
                }

                HStack(alignment: .top, spacing: 14) {
                    StepCard(number: 1, symbol: "folder.fill", title: "Find the game",
                             text: "In any folder or on any disk: Downloads, an external drive, a disc image.")
                    StepCard(number: 2, symbol: "cursorarrow.click.2", title: "Double-click its .exe",
                             text: "Or drag the file onto the Rum icon in the Dock.")
                    StepCard(number: 3, symbol: "play.fill", title: "Play",
                             text: "On the first launch Rum picks the settings that work and remembers them.")
                }
                // Equal heights: each card fills the row, and the row is as tall as the tallest card.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 720)
            }
            .padding(40)
        }
    }
}

private struct StepCard: View {
    let number: Int
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(Color.rum)
                    .frame(height: 28)
                Spacer()
                Text(number, format: .number)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(.quaternary, in: .circle)
            }
            Text(title)
                .font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6))
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    LibraryView(components: ComponentsModel()).frame(width: 900, height: 600)
}
