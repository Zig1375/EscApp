import EscAppKit
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

/// The game's name, and a pencil that turns it into a field: Return keeps the new name, Escape the old one.
struct GameTitle: View {
    let game: GameRecord
    let library: LibraryModel
    // A flag and a plain string: a field bound through `Binding($optional)` crashed EscApp when saving set the
    // optional back to nil while the field was still being laid out.
    @State private var isEditing = false
    @State private var draft = ""
    @State private var isHovered = false
    /// One line of the 26-pt title with a little room above and below.
    private static let boxHeight: CGFloat = 40
    @FocusState private var focused: Bool

    var body: some View {
        if isEditing {
            TextField("Game name", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 26, weight: .bold))
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: Self.boxHeight, alignment: .leading)
                .background(Color.cardBackground, in: .rect(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.brand, lineWidth: 2)
                }
                .padding(.horizontal, -8)
                .focused($focused)
                // Set on appear, the focus didn't reach the new field and typing went nowhere.
                .task {
                    try? await Task.sleep(for: .milliseconds(50))
                    focused = true
                }
                .onSubmit(save)
                .onExitCommand { isEditing = false }
                .onChange(of: focused) { if !focused { save() } }
        } else if game.canRename {
            // The name itself is the control: under the pointer it gets the field's frame, a click makes it the
            // field. The pencil after it says so before the pointer gets there.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(game.name)
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(2)
                Image(systemName: "pencil")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isHovered ? Color.primary : Color.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            // The same box as the field, so the frame doesn't jump or change size on click.
            .frame(maxWidth: .infinity, minHeight: Self.boxHeight, alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isHovered ? Color.buttonBorder : .clear, lineWidth: 2)
            }
            .padding(.horizontal, -8)
            .contentShape(.rect)
            .onHover { isHovered = $0 }
            .pointerStyle(.horizontalText)
            .onTapGesture(perform: edit)
            .help("Click to rename")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Rename")
            .accessibilityAction { edit() }
        } else {
            // A store game keeps the name its store gives it.
            Text(game.name)
                .font(.system(size: 26, weight: .bold))
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func edit() {
        draft = game.name
        isHovered = false
        isEditing = true
    }

    private func save() {
        guard isEditing else { return }
        isEditing = false
        library.rename(game, to: draft)
    }
}
