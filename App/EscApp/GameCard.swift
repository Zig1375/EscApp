import EscAppKit
import SwiftUI

/// One game: tinted icon square, name, when and how long it was played, "About" and "Play".
struct GameCard: View {
    let game: GameRecord
    let library: LibraryModel
    let showDetails: () -> Void
    @State private var isHovered = false

    /// Play, or Stop while the game runs; nothing while it starts.
    private var tileAction: TileAction<GameIconTile>.Action? {
        switch library.states[game.id] {
        case nil: .init(symbol: "play.fill", label: "Play", primary: true) { library.play(game) }
        case .running?: .init(symbol: "stop.fill", label: "Stop", primary: false) { library.stop(game) }
        case .starting?: nil
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            // Variant З of the running-card design: play or stop on the icon, under the pointer.
            TileAction(action: tileAction) {
                GameIconTile(game: game, library: library, size: 84, iconSize: 60, radius: 14)
            }
            VStack(alignment: .leading, spacing: 6) {
                Button(action: showDetails) {
                    Text(game.name)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                HStack(spacing: 8) {
                    if case let .running(since)? = library.states[game.id] {
                        RunningBadge(since: since, now: library.now)
                    } else {
                        if let store = game.store {
                            Pill(text: LocalizedStringKey(store.name), background: store.pillColors.background,
                                 foreground: store.pillColors.text)
                        } else if game.lastPlayed == nil {
                            Pill(text: "New", background: .newBackground, foreground: .newText)
                        }
                        Text(GameText.summary(game))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondaryText)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // One above the other, so a running game's status keeps its line: three buttons in a row squeezed it
            // into a column.
            VStack(spacing: 6) {
                PlayButton(game: game, library: library, card: true)
                Button(action: showDetails) { Label("About", systemImage: "info.circle") }
                    .buttonStyle(BrandButtonStyle(height: 36, fill: true))
            }
            .frame(width: 160)
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 14))
        .background(Color.cardBackground, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isHovered ? Color.cardBorderHover : .cardBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(isHovered ? 0.10 : 0.04), radius: isHovered ? 12 : 1, y: isHovered ? 10 : 1)
        .onHover {
            isHovered = $0
            library.hovering(game, $0)
        }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .contextMenu {
            Button("About", action: showDetails)
            if case .running? = library.states[game.id] {
                Button("Stop") { library.stop(game) }
            }
            Button("Show in Finder") { library.showInFinder(game) }
            if let log = library.latestLog(for: game) {
                Button("Show Last Log") { library.openLog(log) }
            }
            Divider()
            Button("Delete…", role: .destructive) { library.delete(game) }
                .disabled(library.states[game.id] != nil)
        }
    }
}

/// The amber "Play" button, which turns into "Stop" while the game runs.
/// - Parameter card: the library card's version: one button the card's width, "Show Game" while the game runs
///   (Stop is on the card's icon).
struct PlayButton: View {
    let game: GameRecord
    let library: LibraryModel
    var large = false
    var card = false

    var body: some View {
        switch library.states[game.id] {
        case .starting?:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting…").foregroundStyle(Color.secondaryText)
            }
            .font(.system(size: 13))
            .frame(height: large ? 40 : card ? 36 : 34)
        case .running? where card:
            Button { library.showGame(game) } label: { Label("Show Game", systemImage: "arrow.up.forward.app") }
                .buttonStyle(BrandButtonStyle(kind: .primary, height: 36, fill: true))
        case nil where card:
            Button { library.play(game) } label: { Label("Play", systemImage: "play.fill") }
                .buttonStyle(BrandButtonStyle(kind: .primary, height: 36, fill: true))
        case .running?:
            // Launching.dc.html, "Game is running": Show Game and Stop.
            HStack(spacing: 8) {
                Button("Stop") { library.stop(game) }
                    .buttonStyle(BrandButtonStyle(height: large ? 40 : 34))
                Button("Show Game") { library.showGame(game) }
                    .buttonStyle(BrandButtonStyle(kind: .primary, height: large ? 40 : 34))
            }
        case nil:
            Button {
                library.play(game)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.system(size: large ? 15 : 13, weight: large ? .semibold : .medium))
                    .padding(.horizontal, large ? 12 : 0)
            }
            .buttonStyle(BrandButtonStyle(kind: .primary, height: large ? 40 : 34))
        }
    }
}

/// A card's icon that becomes a button under the pointer: a round Play or Stop over it, darkened (variant З of
/// the running-card design). Without an action it is just the icon.
struct TileAction<Tile: View>: View {
    struct Action {
        var symbol: String
        var label: LocalizedStringKey
        /// Amber, like Play; otherwise light, like Stop.
        var primary: Bool
        var run: () -> Void
    }

    let action: Action?
    /// The tile's corner radius, for the darkening.
    var radius: CGFloat = 14
    @ViewBuilder let tile: Tile
    @State private var isHovered = false

    var body: some View {
        if let action {
            Button(action: action.run) {
                tile.overlay {
                    if isHovered {
                        ZStack {
                            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.black.opacity(0.55))
                            Circle()
                                .fill(action.primary ? Color.brandButton : Color(white: 0.93))
                                .frame(width: 40, height: 40)
                            Image(systemName: action.symbol)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(action.primary ? Color.white : Color.black.opacity(0.85))
                        }
                        .transition(.opacity)
                    }
                }
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .accessibilityLabel(Text(action.label))
            .help(Text(action.label))
        } else {
            tile
        }
    }
}
