import ExePortKit
import SwiftUI

/// "Getting the game ready" (Launching.dc.html, first panel): the steps until the game's window appears.
struct LaunchSheet: View {
    let launch: LibraryModel.Launch
    let library: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(launch.firstTime ? "First launch" : "Starting")
                .font(.system(size: 12, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Color.secondaryText)
            HStack(spacing: 12) {
                if let game = library.game(launch.id) {
                    GameIconTile(game: game, library: library, size: 44, iconSize: 34, radius: 11)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(launch.name).font(.system(size: 16, weight: .semibold))
                    Text(launch.firstTime ? "Getting the game ready for its first launch" : "Getting the game ready")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryText)
                }
            }
            StepRow(state: launch.windowsState, title: windowsTitle, detail: windowsDetail)
            if let graphics = launch.graphics {
                StepRow(state: .done, title: "Graphics: \(graphics)", detail: nil)
            }
            VStack(alignment: .leading, spacing: 6) {
                StepRow(state: launch.startState, title: "Starting the game", detail: nil)
                if launch.startState == .active {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(.brand)
                        .padding(.leading, 34)
                    if launch.slow {
                        Text("Wine is still starting. The first launch can take up to a minute.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondaryText)
                            .padding(.leading, 34)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { library.cancelLaunch() }
                    .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 8)
        }
        .padding(22)
        .frame(width: 520)
        .background(Color.cardBackground)
    }

    private var windowsTitle: LocalizedStringKey {
        "Its own \(launch.windows?.version.displayName ?? WindowsVersion.default.displayName)"
    }

    private var windowsDetail: LocalizedStringKey? {
        guard let windows = launch.windows else { return nil }
        if windows.firstTime { return "once, about 30 s" }
        return launch.windowsState == .done ? "instant" : nil
    }
}

private struct StepRow: View {
    let state: LibraryModel.Launch.StepState
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(background)
                switch state {
                case .done: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                case .active: ProgressView().controlSize(.mini)
                case .waiting: EmptyView()
                }
            }
            .foregroundStyle(foreground)
            .frame(width: 22, height: 22)
            Text(title)
                .foregroundStyle(state == .waiting ? Color.secondaryText : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
            }
        }
        .font(.system(size: 14))
    }

    private var background: Color {
        switch state {
        case .done: .newBackground
        case .active: .navSelected
        case .waiting: .chip
        }
    }

    private var foreground: Color { state == .done ? .newText : .brand }
}
