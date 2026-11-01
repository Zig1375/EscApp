import PlavioxKit
import SwiftUI

/// One game as a 3:4 cover with its name under it (Main.dc.html in the main-screen canvas). Steam games show
/// Steam's cover; games the player installed themselves usually have none, only the .exe icon, which then sits on
/// a tint of its own colour. A click on the card starts the game (or brings a running one forward): that's what a
/// player expects from a cover, so under the pointer a play symbol sits in the middle and only About slides up below.
struct GameCard: View {
    let game: GameRecord
    let library: LibraryModel
    let showDetails: () -> Void
    @State private var isHovered = false
    /// Under the pointer About takes the click, not the card, so the play symbol steps aside.
    @State private var isAboutHovered = false

    private var state: LibraryModel.PlayState? { library.states[game.id] }
    /// Components are updating: the card shows that it has to wait instead of offering Play.
    private var waitsForUpdate: Bool { state == nil && library.isUpdatingComponents }
    /// Opened during the update (a double-click on its exe): it starts by itself when the update finishes.
    private var startsAfterUpdate: Bool { waitsForUpdate && library.startsAfterUpdate.contains(game.id) }
    /// The game's folder was moved or deleted: the card says so, since its icon is gone too.
    private var filesMissing: Bool { state == nil && library.missingFiles.contains(game.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
                .offset(y: isHovered ? -3 : 0)
            Text(game.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isHovered ? Color.brand : .primary)
                // Two lines, cut in the middle: on one line cut at the end, "Ru_Daughter_For_Dessert Ch1" and
                // "…Ch2" both read "Ru_Daughter_For_De…". Every card keeps room for two, so the rows line up.
                .lineLimit(2, reservesSpace: true)
                .truncationMode(.middle)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .help(game.name)
        }
        .contentShape(.rect)
        .onTapGesture(perform: activate)
        .onHover {
            isHovered = $0
            library.hovering(game, $0)
        }
        .animation(.easeOut(duration: 0.18), value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(game.name))
        .accessibilityAction(named: Text("Play"), activate)
        .contextMenu {
            if state == nil {
                Button("Play") { library.play(game) }
                    .disabled(!library.canPlay(game) || filesMissing)
            }
            Button("About", action: showDetails)
            if case .running? = state {
                Button("Stop") { library.stop(game) }
            }
            Button("Show in Finder") { library.showInFinder(game) }
            if game.canRename {
                Button("Rename…") { library.renaming = game }
            }
            Button(library.customCovers.contains(game.id) ? "Change Cover…" : "Choose Cover…") {
                library.chooseCover(for: game)
            }
            if library.customCovers.contains(game.id) {
                Button("Remove Cover") { library.removeCover(for: game) }
            }
            Divider()
            Button("Delete…", role: .destructive) { library.delete(game) }
                .disabled(state != nil)
        }
    }

    private func activate() {
        switch state {
        // Nothing to start: the game's page says what happened and how to get it back.
        case nil where filesMissing: showDetails()
        case nil: if library.canPlay(game) { library.play(game) }
        case .running?: library.showGame(game)
        case .starting?: break
        }
    }

    private var cover: some View {
        GameCoverArt(game: game, library: library)
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
                    .opacity(isHovered || state != nil || startsAfterUpdate || filesMissing ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay {
                // A grey symbol of what's wrong instead of Play when the game can't start from here.
                Image(systemName: filesMissing ? "questionmark.folder" : waitsForUpdate ? "hourglass" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: waitsForUpdate || filesMissing ? 0 : 2)
                    .frame(width: 52, height: 52)
                    .background(waitsForUpdate || filesMissing ? Color.gray : Color.brand, in: .circle)
                    // A white ring keeps the amber circle apart from a brown or orange cover.
                    .overlay { Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2) }
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
                    .scaleEffect(isHovered ? 1 : 0.85)
                    .opacity(isHovered && !isAboutHovered && state == nil ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .bottom) { bar.padding(8) }
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isHovered ? Color.brand : Color.black.opacity(0.06), lineWidth: isHovered ? 2 : 1)
            }
            .shadow(color: .black.opacity(isHovered ? 0.22 : 0.08), radius: isHovered ? 14 : 1, y: isHovered ? 12 : 1)
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
        // Before anything else the game might need: without its files nothing else matters.
        case nil where filesMissing && !isHovered:
            HStack(spacing: 6) {
                Image(systemName: "questionmark.folder")
                Text("Files not found").lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .padding(.leading, 4)
            .help(Text("Plaviox can't find \(game.executable)"))
        // A DirectX 12 game without D3DMetal says so before the click, which opens the explanation.
        case nil where library.directX12Needs[game.id] != nil && !waitsForUpdate && !isHovered:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                Text("Needs DirectX 12").lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .padding(.leading, 4)
        case nil where startsAfterUpdate && !isHovered:
            HStack(spacing: 6) {
                Image(systemName: "hourglass")
                Text("Starts after the update").lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .padding(.leading, 4)
        case nil:
            VStack(spacing: 6) {
                if filesMissing {
                    Text("Files not found")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                } else if waitsForUpdate {
                    Group {
                        if startsAfterUpdate {
                            Text("Starts after the update")
                        } else {
                            Text("Playable after the update")
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                }
                aboutButton
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

    /// The game's page, as wide as the card, frosted like the cover's square buttons.
    private var aboutButton: some View {
        Button(action: showDetails) {
            Label("About", systemImage: "info.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(.white.opacity(isAboutHovered ? 0.32 : 0.18),
                            in: .rect(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.white.opacity(isAboutHovered ? 0.5 : 0.28))
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isAboutHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isAboutHovered)
    }
}

/// A game's cover as on its library card (Main.dc.html in the main-screen canvas): the picture, or its icon on a
/// tint of its own colour, and the store's badge in the corner. The card and the game's page both show it.
struct GameCoverArt: View {
    let game: GameRecord
    let library: LibraryModel
    var iconSize: CGFloat = 80
    var badgeSize: CGFloat = 24

    var body: some View {
        Color.clear
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay { artwork }
            .overlay(alignment: .topLeading) {
                if let store = game.store {
                    StoreLogo(store: store, size: badgeSize)
                        .overlay {
                            RoundedRectangle(cornerRadius: badgeSize / 4, style: .continuous)
                                .strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
                        }
                        .padding(badgeSize / 3)
                        .help(Text(store.name))
                }
            }
    }

    @ViewBuilder private var artwork: some View {
        if let image = library.covers[game.id] {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .accessibilityHidden(true)
        } else {
            // No cover: the icon, a little above the middle, on a tint of its own colour.
            ZStack {
                Color.cardBackground
                (library.tints[game.id] ?? .brand).opacity(0.2)
                GameIconTile(game: game, library: library, size: iconSize, iconSize: iconSize, radius: iconSize * 0.24,
                             plain: true)
                    .offset(y: -iconSize * 0.15)
            }
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
            .disabled(!library.canPlay(game) || library.missingFiles.contains(game.id))
            .help(library.isUpdatingComponents ? Text("Playable after the update") : Text(verbatim: ""))
        }
    }
}
