import EscAppKit
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
