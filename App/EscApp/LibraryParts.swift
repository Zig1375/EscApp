import EscAppKit
import SwiftUI

/// The blue strip under the toolbar when newer components are out.
struct UpdateStrip: View {
    let components: ComponentsModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
            if components.updating == nil {
                Button("Update") { Task { await components.installUpdate() } }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                SettingsLink { Text("Details") }
                    .buttonStyle(.plain)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.infoText)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color.infoBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.infoBorder).frame(height: 1) }
    }

    private var message: String {
        if let progress = components.updating { return progress.label }
        guard case let .updateAvailable(current, newest)? = components.catalog?.status else { return "" }
        let versions = RuntimeCatalog.changes(from: current, to: newest)
            .compactMap { change in change.newVersion.map { "\(change.kind.title) \($0)" } }
            .formatted(.list(type: .and))
        return String(localized: """
            \(versions) is out. It installs next to the current version; games keep their saves and settings.
            """)
    }
}

/// The line at the bottom: how games get in, and the offer to open .exe files with EscApp.
struct HintLine: View {
    let library: LibraryModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text("""
                To add a game, double-click its .exe or .msi in Finder, or drag the file onto the EscApp icon \
                in the Dock.
                """)
            if !library.isDefaultForExe {
                Button("Open .exe Files with EscApp") { library.makeDefaultForExe() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.brand)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.secondaryText)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.windowBackground)
    }
}

struct EmptyLibraryView: View {
    var body: some View {
        ZStack {
            WarmBackground()
            VStack(spacing: 32) {
                BrandHero()

                VStack(spacing: 10) {
                    Text("Your games will appear here")
                        .font(.largeTitle.weight(.bold))
                    Text("EscApp runs Windows games on this Mac. Just open a game, and it takes care of the rest.")
                        .font(.title3)
                        .foregroundStyle(Color.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 480)
                }

                HStack(alignment: .top, spacing: 14) {
                    StepCard(number: 1, symbol: "folder.fill", title: "Find the game",
                             text: "In any folder or on any disk: Downloads, an external drive, a disc image.")
                    StepCard(number: 2, symbol: "cursorarrow.click.2", title: "Double-click its .exe",
                             text: "Or drag the file onto the EscApp icon in the Dock.")
                    StepCard(number: 3, symbol: "play.fill", title: "Start playing",
                             text: "On the first launch EscApp picks the settings that work and remembers them.")
                }
                // Equal heights: each card fills the row, and the row is as tall as the tallest card.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 720)
            }
            .padding(40)
        }
    }
}

private struct StepCard: View {
    let number: Int
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(Color.brand)
                    .frame(height: 28)
                Spacer()
                Text(number, format: .number)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.secondaryText)
                    .frame(width: 24, height: 24)
                    .background(Color.chip, in: .circle)
            }
            Text(title)
                .font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.cardBackground, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cardBorder)
        }
        .accessibilityElement(children: .combine)
    }
}
