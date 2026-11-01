import MagicKettleKit
import SwiftUI

/// The game's cover on its page, 200 wide, and under it "Choose Cover…" (or "Change Cover…" and "Remove").
/// Most games the player installed themselves have no cover from a store, only an icon.
struct PageCover: View {
    let game: GameRecord
    let library: LibraryModel

    private var isCustom: Bool { library.customCovers.contains(game.id) }

    var body: some View {
        VStack(spacing: 10) {
            GameCoverArt(game: game, library: library, iconSize: 104, badgeSize: 30)
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.black.opacity(0.06))
                }
                .shadow(color: .black.opacity(0.12), radius: 8, y: 6)
                .contextMenu { menu }
            HStack(spacing: 6) {
                Button(isCustom ? "Change Cover…" : "Choose Cover…") { library.chooseCover(for: game) }
                    .buttonStyle(BrandButtonStyle(height: 28, small: true, fill: true))
                if isCustom {
                    Button { library.removeCover(for: game) } label: { Image(systemName: "trash") }
                        .buttonStyle(BrandButtonStyle(height: 26, small: true))
                        .help("Remove Cover")
                        .accessibilityLabel("Remove Cover")
                }
            }
        }
        .frame(width: 200)
    }

    @ViewBuilder private var menu: some View {
        Button(isCustom ? "Change Cover…" : "Choose Cover…") { library.chooseCover(for: game) }
        if isCustom {
            Button("Remove Cover") { library.removeCover(for: game) }
        }
    }
}

/// The game's name, editable in place for the player's own games: Return keeps the new name, Escape the old one.
struct GameTitle: View {
    let game: GameRecord
    let library: LibraryModel
    @State private var draft = ""
    @State private var isHovered = false
    @FocusState private var focused: Bool
    /// The box in window coordinates, for telling a click outside it.
    @State private var box: CGRect = .zero
    @State private var clickWatch: Any?
    /// One line of the 26-pt title with a little room above and below.
    private static let boxHeight: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
            if let original = game.originalName {
                // Renamed: what it was called, and the way back.
                HStack(spacing: 6) {
                    Text("Original name: \(original)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button { library.restoreName(of: game) } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Restore the Original Name")
                    .accessibilityLabel("Restore the Original Name")
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
            }
        }
    }

    @ViewBuilder private var title: some View {
        if game.canRename {
            // Always a field, drawn as a plain title until the pointer comes (a grey frame) or it is being typed
            // in (the brand frame). As a title that turned into a field on click, it couldn't be selected straight
            // away: dragging over "Ru_" to delete it did nothing.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // The field is as wide as the name (the hidden copy sets the size), so the pencil sits right after
                // it rather than at the far end of the row.
                Text(draft + " ")
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(2)
                    .hidden()
                    .overlay(alignment: .topLeading) {
                        TextField("Game name", text: $draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 26, weight: .bold))
                            .lineLimit(1...2)
                            .focused($focused)
                            .onSubmit { focused = false }
                            .onExitCommand {
                                draft = game.name
                                focused = false
                            }
                    }
                if !focused {
                    Image(systemName: "pencil")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(isHovered ? Color.primary : Color.secondaryText)
                        .onTapGesture { focused = true }
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, minHeight: Self.boxHeight, alignment: .leading)
            .background(focused ? Color.cardBackground : .clear, in: .rect(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? Color.brand : isHovered ? Color.buttonBorder : .clear, lineWidth: 2)
            }
            .padding(.horizontal, -8)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box = $0 }
            .onHover { isHovered = $0 }
            .help("Click to rename")
            .onAppear { draft = game.name }
            .onChange(of: game.name) { if !focused { draft = game.name } }
            .onChange(of: focused) { if !focused { save() } }
            .onAppear(perform: watchClicks)
            // "All Games" while typing: the field goes without losing focus first.
            .onDisappear {
                save()
                if let clickWatch { NSEvent.removeMonitor(clickWatch) }
                clickWatch = nil
            }
        } else {
            // A store game keeps the name its store gives it.
            Text(game.name)
                .font(.system(size: 26, weight: .bold))
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    /// A click anywhere outside the title ends typing, which keeps the new name. A click on the page's empty
    /// space or on a button doesn't take the focus on macOS, so without this the field kept it and the new name
    /// was never saved.
    private func watchClicks() {
        guard clickWatch == nil else { return }
        clickWatch = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                if focused, let content = event.window?.contentView {
                    let point = CGPoint(x: event.locationInWindow.x,
                                        y: content.bounds.height - event.locationInWindow.y)
                    if !box.contains(point) { focused = false }
                }
            }
            return event
        }
    }

    /// Return or leaving the field keeps the new name; an empty one puts the old name back.
    private func save() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != game.name else {
            draft = game.name
            return
        }
        library.rename(game, to: name)
    }
}
