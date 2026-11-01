import MagicKettleKit
import SwiftUI

/// Advanced → launch settings: what Magic Kettle found by launching the game, and "Find Launch Settings Again" to have
/// the next launch look for them as the first one did. The same happens by itself after the game's exe changes
/// (`GameRecord.forgetLaunchSettings`); this is for a game that started misbehaving without an update.
struct LaunchSettingsCard: View {
    let game: GameRecord
    let library: LibraryModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Launch settings").font(.system(size: 14, weight: .semibold))
                Group {
                    if let backend = game.backend {
                        Text("Found by Magic Kettle: \(backend.displayName). What you set here stays.")
                    } else {
                        Text("Looked for at the next launch, as at the first.")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Find Launch Settings Again") {
                library.changeSetting(of: game.id) { $0.forgetLaunchSettings() }
                // The same settings in the game's folder would only be tried first again.
                GameIdentifier.recommend(nil, for: game)
            }
            .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
            .disabled(!game.hasLaunchSettings || library.isPlaying(game.id))
        }
        .padding(20)
        .background(Color.cardBackground, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cardBorder) }
    }
}
