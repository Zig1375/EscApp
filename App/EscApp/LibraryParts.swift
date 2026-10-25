import EscAppKit
import SwiftUI

/// The blue strip under the toolbar when newer components are out.
struct UpdateStrip: View {
    let components: ComponentsModel
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
            if components.updating == nil {
                Button("Update") { Task { await components.installUpdate() } }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                // What changes, right here: it used to open Settings, which only repeated the versions.
                Button("Details") { showsDetails = true }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showsDetails, arrowEdge: .bottom) { UpdateDetails(components: components) }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.infoText)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color.infoBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.infoBorder).frame(height: 1) }
    }

    private var message: String {
        if let progress = components.updating { return progress.label }
        guard case let .updateAvailable(current, newest)? = components.catalog?.status else { return "" }
        let versions = RuntimeCatalog.changes(from: current, to: newest)
            .compactMap { change in change.newVersion.map { "\(change.kind.title) \($0)" } }
            .formatted(.list(type: .and))
        return String(localized: """
            \(versions) is out. It replaces the current version; games keep their saves and settings.
            """)
    }
}

/// The strip's "Details": each component from → to, the download size, and what happens to games.
private struct UpdateDetails: View {
    let components: ComponentsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's New")
                .font(.system(size: 15, weight: .bold))
            if case let .updateAvailable(current, newest)? = components.catalog?.status {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(RuntimeCatalog.changes(from: current, to: newest), id: \.kind) { change in
                        GridRow {
                            Text(change.kind.title).fontWeight(.semibold)
                            Text(verbatim: change.oldVersion ?? "—").foregroundStyle(Color.secondaryText)
                            Image(systemName: "arrow.right").foregroundStyle(Color.secondaryText)
                            Text(verbatim: change.newVersion ?? "—")
                        }
                    }
                }
                Text("Download: \(downloadSize(from: current, to: newest).formatted(.byteCount(style: .file)))")
                    .foregroundStyle(Color.secondaryText)
            }
            Text("""
                The old version is removed after the update. Each game moves to the new one by itself at its next \
                launch; saves and settings stay.
                """)
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
        .padding(16)
        .frame(width: 380, alignment: .leading)
    }

    private func downloadSize(from current: RuntimeManifest.Runtime, to newest: RuntimeManifest.Runtime) -> Int64 {
        let have = Set(current.components.map(\.sha256))
        return newest.components.filter { !have.contains($0.sha256) }.map(\.size).reduce(0, +)
    }
}

/// The line at the bottom: how games get in, and the offer to open .exe files with EscApp.
struct HintLine: View {
    let library: LibraryModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text("""
                To add a game, double-click its .exe or .msi in Finder, or drag the file or its disc image \
                onto the EscApp icon in the Dock.
                """)
            if !library.isDefaultForExe {
                Button("Open .exe Files with EscApp") { library.makeDefaultForExe() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.brand)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.secondaryText)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.windowBackground)
    }
}

struct EmptyLibraryView: View {
    let stores: () -> Void

    var body: some View {
        ZStack {
            WarmBackground()
            VStack(spacing: 32) {
                BrandHero()

                VStack(spacing: 10) {
                    Text("Your games will appear here")
                        .font(.largeTitle.weight(.bold))
                    Text("EscApp runs Windows games on this Mac. Just open a game, and it takes care of the rest.")
                        .font(.title3)
                        .foregroundStyle(Color.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 480)
                }

                HStack(alignment: .top, spacing: 14) {
                    StepCard(number: 1, symbol: "folder.fill", title: "Find the game",
                             text: "In any folder or on any disk: Downloads, an external drive, a disc image.")
                    StepCard(number: 2, symbol: "cursorarrow.click.2", title: "Double-click its .exe",
                             text: "Or drag the file onto the EscApp icon in the Dock.")
                    StepCard(number: 3, symbol: "play.fill", title: "Start playing",
                             text: "On the first launch EscApp picks the settings that work and remembers them.")
                }
                // Equal heights: each card fills the row, and the row is as tall as the tallest card.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 720)

                HStack(spacing: 12) {
                    StoreStack(size: 22)
                    Text("Games in Steam, Epic or another store?")
                        .foregroundStyle(Color.secondaryText)
                    Button("Install a Store", action: stores)
                        .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
                }
                .font(.system(size: 14))
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
                    .foregroundStyle(Color.brand)
                    .frame(height: 28)
                Spacer()
                Text(number, format: .number)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.secondaryText)
                    .frame(width: 24, height: 24)
                    .background(Color.chip, in: .circle)
            }
            Text(title)
                .font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.cardBackground, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cardBorder)
        }
        .accessibilityElement(children: .combine)
    }
}

struct Pill: View {
    let text: LocalizedStringKey
    let background: Color
    let foreground: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(background, in: .capsule)
    }
}

/// Wording shared by the card, the game page and the menu bar.
enum GameText {
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(localized: "under a minute") }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

/// The icon on a light square of its own main colour; an edge-to-edge icon fills the square instead.
struct GameIconTile: View {
    let game: GameRecord
    let library: LibraryModel
    let size: CGFloat
    let iconSize: CGFloat
    let radius: CGFloat
    /// Without the square: the library card already paints the tint across the whole cover.
    var plain = false

    var body: some View {
        if let image = library.icons[game.id], library.fullBleedIcons.contains(game.id) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: radius, style: .continuous))
                .accessibilityHidden(true)
        } else {
            inset
        }
    }

    private var inset: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill((library.tints[game.id] ?? .brand).opacity(plain ? 0 : 0.2))
            .frame(width: size, height: size)
            .overlay {
                if let image = library.icons[game.id] {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: iconSize, height: iconSize)
                        .shadow(color: .black.opacity(0.25), radius: 5, y: 6)
                } else {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: iconSize * 0.5))
                        .foregroundStyle(Color.brand)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Green dot, "Running · 12 min" (Launching.dc.html).
struct RunningBadge: View {
    let since: Date
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.green).frame(width: 8, height: 8)
            Text("Running · \(GameText.duration(max(now, Date()).timeIntervalSince(since)))")
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.okText)
    }
}

/// Settings' smaller button: 30 high, radius 8, 12-pt sides.
struct CompactButtonStyle: ButtonStyle {
    var kind: BrandButtonStyle.Kind = .plain

    func makeBody(configuration: Configuration) -> some View {
        BrandButtonStyle(kind: kind, height: 30, radius: 8).makeBody(configuration: configuration)
    }
}

/// The field in the card's "Rename…" alert, starting with the current name.
struct RenameField: View {
    let game: GameRecord
    let library: LibraryModel
    @State private var name = ""

    var body: some View {
        TextField("Game name", text: $name)
            .onAppear { name = game.name }
        Button("Rename") { library.rename(game, to: name) }
        Button("Cancel", role: .cancel) {}
    }
}
