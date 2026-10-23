import AppKit
import SwiftUI

@main
struct ExePortApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var setup = RuntimeSetup()
    @State private var components = ComponentsModel()

    var body: some Scene {
        Window("ExePort", id: "library") {
            Group {
                if setup.phase == .ready {
                    LibraryView(components: components, library: delegate.library)
                } else {
                    SetupView(setup: setup)
                }
            }
            .frame(minWidth: 960, idealWidth: 1200, minHeight: 600, idealHeight: 780)
            .onChange(of: setup.phase, initial: true) {
                components.reload()
                if setup.phase == .ready { delegate.library.becameReady() }
            }
            .task {
                // Once an hour is plenty: the updater itself only goes to the network once a day.
                while !Task.isCancelled {
                    await components.checkIfDue()
                    try? await Task.sleep(for: .seconds(60 * 60))
                }
            }
        }
        .defaultSize(width: 1200, height: 780)
        // The header is drawn by the app (see WindowChrome); no system title bar or its glass on top of it.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(components: components)
            }
        }

        // Launching.dc.html: a running game shows in the menu bar, so ExePort's window can be closed.
        MenuBarExtra(isInserted: Binding(get: { !delegate.library.runningGames.isEmpty }, set: { _ in })) {
            RunningGamesMenu(library: delegate.library)
        } label: {
            RunningGamesLabel(library: delegate.library)
        }

        Settings {
            SettingsView(components: components, library: delegate.library)
        }
    }
}

/// Receives files opened from Finder or dropped on the Dock icon, which can arrive before any window exists.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let library = LibraryModel()

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { library.open(url) }
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

private struct RunningGamesLabel: View {
    let library: LibraryModel

    var body: some View {
        if let first = library.runningGames.first {
            let time = GameText.duration(max(library.now, Date()).timeIntervalSince(first.since))
            Label("\(first.game.name) · \(time)", systemImage: "gamecontroller.fill")
                .labelStyle(.titleAndIcon)
        }
    }
}

private struct RunningGamesMenu: View {
    let library: LibraryModel

    var body: some View {
        ForEach(library.runningGames, id: \.game.id) { running in
            Text(running.game.name)
            Button("Show Game") { library.showGame(running.game) }
            Button("Stop") { library.stop(running.game) }
            Divider()
        }
        Text("You can close ExePort; the game keeps running.")
    }
}
