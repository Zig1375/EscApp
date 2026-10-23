import SwiftUI

@main
struct RumApp: App {
    var body: some Scene {
        Window("Rum", id: "library") {
            LibraryView()
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowToolbarStyle(.unified)
    }
}
