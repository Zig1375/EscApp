import PlavioxKit
import SwiftUI

/// Under the game's actions while Retina is on for it. A game that doesn't handle Retina gets the mouse position
/// halved by Wine, so clicks miss the buttons it draws; players blamed the game, not the setting that cures it.
/// Closed in one game, it stays closed in that game only (`GameRecord.retinaTipClosed`).
struct RetinaClicksTip: View {
    let game: GameRecord
    let library: LibraryModel

    var body: some View {
        if game.retinaTipClosed != true {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                Text("Clicks miss the game's buttons or land beside them? Set Retina to Off for this game.")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Not `changeSetting`: closing a tip changes nothing in the game's Windows, even while it runs.
                Button { library.update(game.id) { $0.retinaTipClosed = true } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Close Tip")
                .accessibilityLabel("Close Tip")
            }
            .font(.system(size: 13))
            .foregroundStyle(Color.infoText)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: 460, alignment: .leading)
            .background(Color.infoBackground, in: .rect(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.infoBorder) }
        }
    }
}

/// Under the actions of a DirectX 12 game while D3DMetal isn't added (`DirectX12Need`): what the game needs and
/// the way to it, before the player tries Play and learns it from a message.
/// The game's program is no longer where it was (`LibraryModel.missingFiles`): where it was looked for, and the
/// two ways back. Same amber box as the DirectX 12 tip.
struct MissingFilesNote: View {
    let game: GameRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 13, weight: .medium))
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("""
                    Plaviox can't find this game's files. If you moved its folder, open the game from its new \
                    place. If you deleted it, put it back.
                    """)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: game.executable)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .opacity(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.warnText)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 460, alignment: .leading)
        .background(Color.warnBackground, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.warnBorder) }
    }
}

struct DirectX12Tip: View {
    let game: GameRecord
    let library: LibraryModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cpu")
                .font(.system(size: 13, weight: .medium))
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("""
                    This game needs DirectX 12. Add it once, from Apple: it's free and takes a couple of minutes. \
                    Plaviox shows you how.
                    """)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set Up DirectX 12…") {
                    library.directX12Game = game.id
                    openWindow(id: DirectX12Window.id)
                }
                .buttonStyle(CompactButtonStyle(kind: .primary))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.warnText)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 460, alignment: .leading)
        .background(Color.warnBackground, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.warnBorder) }
    }
}

/// Over a running game's settings, which are locked until it ends (`LibraryModel.isPlaying`).
struct ClosedGameNote: View {
    var body: some View {
        Label("Settings can be changed once the game is closed.", systemImage: "lock")
            .font(.system(size: 13))
            .foregroundStyle(Color.infoText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.infoBackground, in: .rect(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.infoBorder) }
    }
}
