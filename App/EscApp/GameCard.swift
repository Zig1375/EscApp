import EscAppKit
import SwiftUI

/// One game as a 3:4 cover with its name under it (Main.dc.html in the main-screen canvas). Steam games show
/// Steam's cover; games the player installed themselves usually have none, only the .exe icon, which then sits on
/// a tint of its own colour. Under the pointer the card lifts and a bar with Play and "…" (About) slides up.
struct GameCard: View {
    let game: GameRecord
    let library: LibraryModel
    let showDetails: () -> Void
    @State private var isHovered = false

    private var state: LibraryModel.PlayState? { library.states[game.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
                .offset(y: isHovered ? -3 : 0)
            Text(game.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isHovered ? Color.brand : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .contentShape(.rect)
        .onTapGesture(perform: showDetails)
        .onHover {
            isHovered = $0
            library.hovering(game, $0)
        }
        .animation(.easeOut(duration: 0.18), value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(game.name))
        .contextMenu {
            Button("About", action: showDetails)
            if case .running? = state {
                Button("Stop") { library.stop(game) }
            }
            Button("Show in Finder") { library.showInFinder(game) }
            if let log = library.latestLog(for: game) {
                Button("Show Last Log") { library.openLog(log) }
            }
            Divider()
            Button("Delete…", role: .destructive) { library.delete(game) }
                .disabled(state != nil)
        }
    }

    private var cover: some View {
        Color.clear
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay { artwork }
            .overlay(alignment: .topLeading) {
                if let store = game.store {
                    StoreLogo(store: store, size: 24)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
                        }
                        .padding(8)
                        .help(Text(store.name))
                }
            }
            .overlay(alignment: .topTrailing) {
                if game.lastPlayed == nil, state == nil {
                    Pill(text: "New", background: .newBackground, foreground: .newText).padding(8)
                }
            }
            .overlay {
                // The bottom half darkens so the white buttons and "Running" read on any cover.
                LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.72),
                                                                                    location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .opacity(isHovered || state != nil ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) { bar.padding(8) }
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isHovered ? Color.brand : Color.black.opacity(0.06), lineWidth: isHovered ? 2 : 1)
            }
            .shadow(color: .black.opacity(isHovered ? 0.22 : 0.08), radius: isHovered ? 14 : 1, y: isHovered ? 12 : 1)
    }

    @ViewBuilder private var artwork: some View {
        if let image = library.covers[game.id] {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .accessibilityHidden(true)
        } else {
            // No cover: the icon, 80 pt, a little above the middle, on a tint of its own colour.
            ZStack {
                Color.cardBackground
                (library.tints[game.id] ?? .brand).opacity(0.2)
                GameIconTile(game: game, library: library, size: 80, iconSize: 80, radius: 19, plain: true)
                    .offset(y: -12)
            }
        }
    }

    /// What's under the cover's bottom edge: starting, the running time, or (under the pointer) the buttons.
    @ViewBuilder private var bar: some View {
        switch state {
        case .starting?:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Starting…")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 34)
        case let .running(since)? where !isHovered:
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Running · \(GameText.duration(max(library.now, Date()).timeIntervalSince(since)))")
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .padding(.leading, 4)
        case .running?:
            // "Показать игру" next to two square buttons is wider than a 150-pt card: it ran off both edges.
            // Where the words don't fit, the button keeps only its symbol.
            ViewThatFits(in: .horizontal) {
                runningButtons { Text("Show Game") }
                runningButtons { Image(systemName: "arrow.up.forward.app") }
            }
        case nil:
            ViewThatFits(in: .horizontal) {
                playButtons { Label("Play", systemImage: "play.fill") }
                playButtons { Image(systemName: "play.fill") }
            }
            .opacity(isHovered ? 1 : 0)
            .offset(y: isHovered ? 0 : 8)
            .allowsHitTesting(isHovered)
        }
    }

    private func runningButtons(@ViewBuilder label: () -> some View) -> some View {
        HStack(spacing: 6) {
            Button { library.showGame(game) } label: { label() }
                .buttonStyle(BrandButtonStyle(kind: .primary, height: 34, fill: true))
                .help("Show Game")
                .accessibilityLabel("Show Game")
            CoverButton(symbol: "stop.fill", label: "Stop") { library.stop(game) }
            CoverButton(symbol: "ellipsis", label: "About", action: showDetails)
        }
    }

    private func playButtons(@ViewBuilder label: () -> some View) -> some View {
        HStack(spacing: 6) {
            Button { library.play(game) } label: { label() }
                .buttonStyle(BrandButtonStyle(kind: .primary, height: 34, fill: true))
                .accessibilityLabel("Play")
            CoverButton(symbol: "ellipsis", label: "About", action: showDetails)
        }
    }
}

/// A 34-pt square button on a cover: white glyph on frosted white.
private struct CoverButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.18), in: .rect(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.28))
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }
}

/// The amber "Play" button, which turns into "Stop" and "Show Game" while the game runs (the game's page).
struct PlayButton: View {
    let game: GameRecord
    let library: LibraryModel
    var large = false

    var body: some View {
        switch library.states[game.id] {
        case .starting?:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting…").foregroundStyle(Color.secondaryText)
            }
            .font(.system(size: 13))
            .frame(height: large ? 40 : 34)
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
