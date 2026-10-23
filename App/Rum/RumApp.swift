import SwiftUI

@main
struct RumApp: App {
    @State private var setup = RuntimeSetup()
    @State private var components = ComponentsModel()

    var body: some Scene {
        Window("Rum", id: "library") {
            Group {
                if setup.phase == .ready {
                    LibraryView(components: components)
                } else {
                    SetupView(setup: setup)
                }
            }
            .frame(minWidth: 760, minHeight: 520)
            .onChange(of: setup.phase) { components.reload() }
            .task {
                components.reload()
                // Once an hour is plenty: the updater itself only goes to the network once a day.
                while !Task.isCancelled {
                    await components.checkIfDue()
                    try? await Task.sleep(for: .seconds(60 * 60))
                }
            }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(components: components)
            }
        }

        Settings {
            SettingsView(components: components)
        }
    }
}

private struct CheckForUpdatesButton: View {
    let components: ComponentsModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Check for Component Updates…") {
            openSettings()
            Task { await components.checkNow() }
        }
    }
}
