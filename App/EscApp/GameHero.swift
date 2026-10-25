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
    @FocusState private var focused: Bool

    var body: some View {
        if isEditing {
            TextField("Game name", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 26, weight: .bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
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
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(game.name)
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                // A store game keeps the name its store gives it.
                if game.canRename {
                    Button {
                        draft = game.name
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.secondaryText)
                            .frame(width: 26, height: 26)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Rename")
                    .accessibilityLabel("Rename")
                }
            }
        }
    }

    private func save() {
        guard isEditing else { return }
        isEditing = false
        library.rename(game, to: draft)
    }
}
