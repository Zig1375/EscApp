import EscAppKit
import SwiftUI

/// Problems.dc.html: one honest message, its icon, what was found, and what can be done.
struct ProblemSheet: View {
    let problem: LibraryModel.Problem
    let library: LibraryModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 40, height: 40)
                .background(iconBackground, in: .rect(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.system(size: 13))
                .lineSpacing(4)
                .foregroundStyle(Color.bodyText)
                .fixedSize(horizontal: false, vertical: true)
            if let found {
                Text(found)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                buttons
            }
            .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 400, alignment: .leading)
        .background(Color.cardBackground)
        .focusEffectDisabled()
    }

    @ViewBuilder private var buttons: some View {
        if case let .needsSteam(id) = problem.kind {
            Button("Run Anyway") {
                library.problem = nil
                if let game = library.game(id) { library.play(game) }
            }
            .keyboardShortcut(.cancelAction)
            // Stores.dc.html, where installing Steam takes one button.
            Button(library.installedStores.contains(.steam) ? "Show Stores" : "Install Steam") {
                library.problem = nil
                library.shownPage = .stores
            }
            .buttonStyle(BrandButtonStyle(kind: .primary, height: 32, radius: 8))
            .keyboardShortcut(.defaultAction)
        } else if case .needsDirectX12 = problem.kind {
            Button("Not Now") { library.problem = nil }
                .keyboardShortcut(.cancelAction)
            Button("Set Up DirectX 12…") {
                library.problem = nil
                UserDefaults.standard.set(SettingsView.Section.directX12.rawValue, forKey: SettingsView.sectionKey)
                openSettings()
            }
            .buttonStyle(BrandButtonStyle(kind: .primary, height: 32, radius: 8))
            .keyboardShortcut(.defaultAction)
        } else if case let .needsDisc(id, _) = problem.kind {
            Button("Cancel") { library.problem = nil }
                .keyboardShortcut(.cancelAction)
            Button("Choose Disc Image…") { library.chooseDisc(for: id) }
                .buttonStyle(BrandButtonStyle(kind: .primary, height: 32, radius: 8))
                .keyboardShortcut(.defaultAction)
        } else {
            Button("Got It") { library.problem = nil }
                .buttonStyle(BrandButtonStyle(kind: .primary, height: 32, radius: 8))
                .keyboardShortcut(.defaultAction)
        }
    }

    private var icon: String {
        switch problem.kind {
        case .sixteenBit: "display"
        case .dos: "terminal"
        case .notWindows: "doc.text"
        case .needsDisc: "opticaldisc"
        case .needsSteam: "bag"
        case .needsDirectX12: "cpu"
        }
    }

    private var iconBackground: Color {
        switch problem.kind {
        case .needsDisc: .installerTag
        case .needsSteam: .warnBackground
        default: .chip
        }
    }

    private var iconColor: Color {
        switch problem.kind {
        case .needsDisc: .installerTagText
        case .needsSteam: .warnText
        default: .bodyText
        }
    }

    private var title: LocalizedStringKey {
        switch problem.kind {
        case .sixteenBit: "A program for Windows 3.x"
        case .dos: "A program for DOS"
        case .notWindows: "This isn't a Windows program"
        case .needsDisc: "The game asks for its disc"
        case .needsSteam: "This game needs Steam"
        case .needsDirectX12: "This game needs DirectX 12"
        }
    }

    private var message: LocalizedStringKey {
        switch problem.kind {
        case .sixteenBit:
            """
            This is a 16-bit program from the early 90s. Today's Wine on a Mac doesn't run such programs. Games \
            like this often have a DOS version or a re-release.
            """
        case .dos:
            """
            This game was made for DOS, before Windows. Wine doesn't run DOS programs; DOSBox does, and many such \
            games are sold with it included.
            """
        case .notWindows:
            """
            The file is called .exe, but there's no Windows program inside. It may be damaged or not fully \
            downloaded.
            """
        case .needsDisc:
            """
            Many old games check for their disc when they start. Choose its disc image (.iso, or .cue with its \
            .bin), and EscApp shows it to the game as drive D:.
            """
        case let .needsSteam(id):
            """
            \(library.game(id)?.name ?? "The game") checks that Steam is running and closes without it. EscApp can \
            install Steam: it lives on its own and won't get in the way of other games.
            """
        case .needsDirectX12:
            """
            DirectX 12 games run on D3DMetal, Apple's translation of DirectX 12 to Metal. Apple doesn't allow EscApp \
            to include it, but you can download it from Apple yourself, for free, in a couple of minutes. EscApp \
            shows you how.
            """
        }
    }

    private var found: LocalizedStringKey? {
        switch problem.kind {
        case .sixteenBit: "File format: NE (16-bit)"
        case .dos: "File format: MZ (DOS)"
        case .notWindows: "No PE header"
        case let .needsDisc(_, message?): "The game said: “\(message)”"
        case .needsDisc(_, nil): nil
        case .needsSteam: "Found in the game's log: SteamAPI_Init() failed"
        case .needsDirectX12: "The game's file uses d3d12.dll"
        }
    }
}

extension View {
    /// Shows the problem sheet while `library` has something to tell.
    func problemSheet(_ library: LibraryModel) -> some View {
        sheet(item: Binding(get: { library.problem }, set: { library.problem = $0 })) { problem in
            ProblemSheet(problem: problem, library: library)
        }
    }
}
