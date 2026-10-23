import RumKit
import SwiftUI

/// The main window. Until launching lands (M3) it only shows the empty state and how games get added.
struct LibraryView: View {
    var body: some View {
        VStack(spacing: 0) {
            ContentUnavailableView {
                Label("No games yet", systemImage: "gamecontroller")
            } description: {
                Text("Double-click a game's .exe in Finder, or drag it onto Rum. Rum sets everything up by itself.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            Text("To add a game, double-click its .exe or .msi, or drag the file onto the Rum icon in the Dock.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 10)
        }
        .navigationTitle("Rum")
    }
}

#Preview {
    LibraryView()
}
