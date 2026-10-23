import EscAppKit
import SwiftUI

/// A game's own page, as in the design (Game.dc.html): the game and its actions, recent runs, and the details
/// column. Parts EscApp can't fill yet (screenshots, saves, Launchpad shortcut, Advanced) are left out rather than
/// shown empty.
struct GamePage: View {
    let id: GameID
    let library: LibraryModel
    let back: () -> Void
    @State private var size: Int64?
    @State private var isDeleting = false

    var body: some View {
        Group {
            if let game = library.game(id) {
                content(game)
                    .sheet(isPresented: $isDeleting) {
                        DeleteGameSheet(game: game, folderSize: size, library: library) { removed in
                            isDeleting = false
                            if removed { back() }
                        }
                    }
                    .task(id: game.folder) { size = await library.folderSize(of: game) }
            } else {
                Text("This game is no longer in EscApp.")
                    .foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.windowBackground)
    }

    private func content(_ game: GameRecord) -> some View {
        ScrollView {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    hero(game)
                    RunsSection(runs: library.runs(for: game), library: library)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DetailsColumn(game: game, size: size, library: library)
                    .frame(width: 380)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
    }

    private func hero(_ game: GameRecord) -> some View {
        HStack(spacing: 20) {
            GameIconTile(game: game, library: library, size: 104, iconSize: 76, radius: 24)
            VStack(alignment: .leading, spacing: 10) {
                Text(game.name)
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let info = library.infos[game.id] {
                    HStack(spacing: 8) {
                        ForEach(chips(info), id: \.self) { Chip(text: $0) }
                    }
                }
                // One row when it fits, otherwise "Play" above the other two (narrow windows).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { actions(game) }
                    VStack(alignment: .leading, spacing: 8) {
                        PlayButton(game: game, library: library, large: true)
                        HStack(spacing: 8) { secondaryActions(game) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func actions(_ game: GameRecord) -> some View {
        PlayButton(game: game, library: library, large: true)
        secondaryActions(game)
    }

    @ViewBuilder private func secondaryActions(_ game: GameRecord) -> some View {
        Button { library.showInFinder(game) } label: { Label("Open Game Folder", systemImage: "folder") }
            .buttonStyle(BrandButtonStyle(height: 40))
        Button("Delete…") { isDeleting = true }
            .buttonStyle(BrandButtonStyle(kind: .danger, height: 40))
    }

    /// "DirectX 11 · 32-bit · Retina", from what the exe imports and declares.
    private func chips(_ info: ExecutableInfo) -> [String] {
        var result: [String] = []
        switch info.directX.max() {
        case .legacy?: result.append("DirectDraw")
        case .d3d9?: result.append("DirectX 9")
        case .d3d11?: result.append("DirectX 11")
        case .d3d12?: result.append("DirectX 12")
        case nil: break
        }
        switch info.format {
        case .pe64: result.append(String(localized: "64-bit"))
        case .pe32: result.append(String(localized: "32-bit"))
        case .win16: result.append(String(localized: "16-bit"))
        case .dos: result.append("DOS")
        }
        if info.dpiAware { result.append("Retina") }
        return result
    }
}

private struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color.chip, in: .capsule)
    }
}

private struct SectionTitle: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(Color.secondaryText)
    }
}

/// A white rounded card of rows separated by thin lines.
private struct RowsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Rectangle().fill(Color.rowDivider).frame(height: 1) }
                    row
                }
            }
        }
        .background(Color.cardBackground, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cardBorder) }
    }
}

private struct RunsSection: View {
    let runs: [LaunchHistory.Run]
    let library: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Recent runs")
            if runs.isEmpty {
                Text("The game hasn't been started yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.secondaryText)
            } else {
                RowsCard {
                    ForEach(Array(runs.prefix(6).enumerated()), id: \.offset) { _, run in
                        row(run)
                    }
                }
            }
        }
    }

    private func row(_ run: LaunchHistory.Run) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(run.worked == true ? Color.green : run.worked == false ? Color.orange : Color.secondaryText)
                .frame(width: 8, height: 8)
            Text(when(run))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(outcome(run))
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
            Button("Log") { library.openLog(run.log) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.brand)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func when(_ run: LaunchHistory.Run) -> String {
        let date = run.startedAt.formatted(.dateTime.day().month(.wide).hour().minute())
        guard let seconds = run.sessionSeconds else { return date }
        return "\(date) · \(GameText.duration(TimeInterval(seconds)))"
    }

    private func outcome(_ run: LaunchHistory.Run) -> String {
        let backend = run.backend?.displayName ?? "?"
        switch run.worked {
        case true?:
            return String(localized: "\(backend) · no errors")
        case false?:
            let seconds = run.processSeconds ?? 0
            return String(localized: "\(backend) · closed after \(seconds) s (code \(run.exitCode ?? 0))")
        case nil:
            return String(localized: "\(backend) · running or interrupted")
        }
    }
}

private struct DetailsColumn: View {
    let game: GameRecord
    let size: Int64?
    let library: LibraryModel

    var body: some View {
        RowsCard {
            DetailRow(label: "Source") { Text("From disk") }
            DetailRow(label: "Folder") {
                Mono(text: (game.folder as NSString).abbreviatingWithTildeInPath)
            } action: {
                Button("Open") { library.showInFinder(game) }.buttonStyle(BrandButtonStyle(small: true))
            }
            DetailRow(label: "Starts") {
                Mono(text: URL(filePath: game.executable).lastPathComponent)
            } action: {
                Button("Change") { library.chooseExecutable(for: game) }.buttonStyle(BrandButtonStyle(small: true))
            }
            DetailRow(label: "Game size") {
                Text(size.map { $0.formatted(.byteCount(style: .file)) } ?? "…")
            }
            DetailRow(label: "System") {
                DesignSelect(selection: Binding(get: { game.windowsVersion },
                                                set: { library.setWindowsVersion($0, for: game) }),
                             options: WindowsVersion.allCases.reversed(),
                             title: { version in
                                 version == .default
                                     ? String(localized: "\(version.displayName) (default)") : version.displayName
                             })
            }
            DetailRow(label: "Graphics") { Text(graphics) }
            DetailRow(label: "Played") { Text(played) }
            DetailRow(label: "Added") { Text(game.addedAt.formatted(date: .long, time: .omitted)) }
        }
    }

    private var graphics: String {
        if let backend = game.backend { return String(localized: "Auto: \(backend.displayName)") }
        guard let info = library.infos[game.id] else { return String(localized: "Auto") }
        switch BackendPlan.forTraits(info.traits) {
        case let .attempts(backends):
            return String(localized: "Auto: \(backends[0].displayName) first")
        case .unsupported:
            return String(localized: "Not supported")
        }
    }

    private var played: String {
        guard let time = game.playTime else { return String(localized: "Not yet") }
        // Games played before the counter existed: their logs still tell (up to the 20 kept).
        let launches = game.launches ?? library.runs(for: game).count
        return "\(GameText.duration(time)) · " + String(localized: "\(launches) launches")
    }
}

private struct DetailRow<Value: View, Action: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let value: Value
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(Color.secondaryText)
                .frame(width: 118, alignment: .leading)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

extension DetailRow where Action == EmptyView {
    init(label: LocalizedStringKey, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
        action = EmptyView()
    }
}

private struct Mono: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(text)
    }
}
