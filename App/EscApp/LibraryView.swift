import AppKit
import EscAppKit
import SwiftUI
import UniformTypeIdentifiers

/// The main window, laid out as in the design (Main.dc.html): toolbar with search, "Open Game…" and settings;
/// an update strip; "Games" with source filters and order; two columns of wide cards; a hint at the bottom.
struct LibraryView: View {
    enum Page: Hashable { case game(GameID), advanced(GameID), stores }

    let components: ComponentsModel
    let library: LibraryModel
    @State private var page: Page?
    @State private var search = ""
    @State private var isTargeted = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            if case let .game(id)? = page {
                GamePage(id: id, library: library, back: { page = nil }, advanced: { page = .advanced(id) })
            } else if case let .advanced(id)? = page {
                AdvancedPage(id: id, library: library)
            } else if page == .stores {
                StoresPage(library: library)
            } else {
                if components.catalog?.updateAvailable == true { UpdateStrip(components: components) }
                if library.games.isEmpty {
                    EmptyLibraryView()
                } else {
                    LibraryScreen(library: library, search: search) { page = .game($0) }
                }
            }
        }
        .background(Color.windowBackground)
        // The design has no keyboard focus rings; macOS draws a blue one around the focused button.
        .focusEffectDisabled()
        .ignoresSafeArea(edges: .top)
        .background(WindowChrome())
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.brand, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in library.open(url) }
                }
            }
            return !providers.isEmpty
        }
        .overlay(alignment: .bottom) {
            if let learned = library.learned {
                LearnedToast(learned: learned) { library.learned = nil }
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: library.learned)
        .sheet(item: Binding(get: { library.launch }, set: { if $0 == nil { library.cancelLaunch() } })) { launch in
            LaunchSheet(launch: launch, library: library)
        }
        .installSheet(library)
        .problemSheet(library)
        .onChange(of: library.showsStores, initial: true) {
            guard library.showsStores else { return }
            library.showsStores = false
            page = .stores
        }
        .alert(library.notice?.title ?? "", isPresented: Binding(get: { library.notice != nil },
                                                                 set: { if !$0 { library.notice = nil } }),
               presenting: library.notice) { notice in
            if let log = notice.log {
                Button("Show Log") { library.openLog(log) }
            }
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        .animation(.default, value: components.catalog?.updateAvailable)
    }

    /// Main.dc.html: "EscApp", then search, "Open Game…" and settings on the right.
    /// Game.dc.html: a single "‹ All Games" button.
    @ViewBuilder private var header: some View {
        HeaderBar {
            if case let .advanced(id)? = page {
                AdvancedHeader(name: library.game(id)?.name ?? "") { page = .game(id) }
            } else if page != nil {
                Button { page = nil } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("All Games")
                    }
                }
                .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
            } else {
                Text("EscApp")
                    .font(.system(size: 15, weight: .bold))
                Spacer(minLength: 0)
                SearchField(text: $search)
                Button { library.chooseGameFile() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                        Text("Open Game…")
                    }
                }
                .buttonStyle(BrandButtonStyle(kind: .primary, height: 32))
                Button { openSettings() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(BrandButtonStyle(height: 32, square: true))
                .help("Settings")
                .accessibilityLabel("Settings")
            }
        }
    }

}

/// "Games", the filters and order, the cards, and the hint line.
private struct LibraryScreen: View {
    enum Filter: Hashable { case all, disk, store(Store) }

    enum Order: String, CaseIterable, Identifiable {
        case recent, name, mostPlayed
        var id: Self { self }
        var title: String.LocalizationValue {
            switch self {
            case .recent: "Recent"
            case .name: "By name"
            case .mostPlayed: "Most played"
            }
        }
    }

    let library: LibraryModel
    let search: String
    let open: (GameID) -> Void
    @AppStorage("LibraryOrder") private var order: Order = .recent
    @State private var filter: Filter = .all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                          spacing: 14) {
                    ForEach(shown) { game in
                        GameCard(game: game, library: library) { open(game.id) }
                    }
                }
                if shown.isEmpty {
                    Text("No games match “\(search)”.")
                        .foregroundStyle(Color.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { HintLine(library: library) }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Games")
                .font(.system(size: 20, weight: .bold))
                .padding(.trailing, 16)
            FilterChip(title: "All · \(library.games.count)", isOn: filter == .all) { filter = .all }
            FilterChip(title: "From disk · \(library.games(from: nil).count)", isOn: filter == .disk) {
                filter = .disk
            }
            // A store's filter shows once it has games (Main.dc.html: "Steam · 1", "GOG Galaxy · 1").
            ForEach(Store.allCases.filter { !library.games(from: $0).isEmpty }) { store in
                FilterChip(title: "\(store.name) · \(library.games(from: store).count)",
                           isOn: filter == .store(store)) { filter = .store(store) }
            }
            Spacer()
            Text("Order")
                .font(.system(size: 13))
                .foregroundStyle(Color.secondaryText)
            DesignSelect(selection: $order, options: Order.allCases, title: { String(localized: $0.title) },
                         width: 180)
        }
    }

    private var shown: [GameRecord] {
        let source: [GameRecord] = switch filter {
        case .all: library.games
        case .disk: library.games(from: nil)
        case let .store(store): library.games(from: store)
        }
        let matching = source.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        switch order {
        case .recent:
            return matching.sorted { ($0.lastPlayed ?? $0.addedAt) > ($1.lastPlayed ?? $1.addedAt) }
        case .name:
            return matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .mostPlayed:
            return matching.sorted { ($0.playTime ?? 0) > ($1.playTime ?? 0) }
        }
    }
}

private struct FilterChip: View {
    let title: LocalizedStringKey
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.chipSelectedText : .primary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(isOn ? Color.chipSelected : .clear, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// One game: tinted icon square, name, when and how long it was played, "About" and "Play".
struct GameCard: View {
    let game: GameRecord
    let library: LibraryModel
    let showDetails: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 16) {
            GameIconTile(game: game, library: library, size: 84, iconSize: 60, radius: 14)
            VStack(alignment: .leading, spacing: 6) {
                Button(action: showDetails) {
                    Text(game.name)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                HStack(spacing: 8) {
                    if case let .running(since)? = library.states[game.id] {
                        RunningBadge(since: since, now: library.now)
                    } else {
                        if let store = game.store {
                            Pill(text: LocalizedStringKey(store.name), background: store.pillColors.background,
                                 foreground: store.pillColors.text)
                        } else if game.lastPlayed == nil {
                            Pill(text: "New", background: .newBackground, foreground: .newText)
                        }
                        Text(GameText.summary(game))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondaryText)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("About", action: showDetails)
                .buttonStyle(.brand)
            PlayButton(game: game, library: library)
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 14))
        .background(Color.cardBackground, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isHovered ? Color.cardBorderHover : .cardBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(isHovered ? 0.10 : 0.04), radius: isHovered ? 12 : 1, y: isHovered ? 10 : 1)
        .onHover {
            isHovered = $0
            library.hovering(game, $0)
        }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .contextMenu {
            Button("About", action: showDetails)
            Button("Show in Finder") { library.showInFinder(game) }
            if let log = library.latestLog(for: game) {
                Button("Show Last Log") { library.openLog(log) }
            }
        }
    }
}

/// The amber "Play" button, which turns into "Stop" while the game runs.
struct PlayButton: View {
    let game: GameRecord
    let library: LibraryModel
    var large = false

    var body: some View {
        switch library.states[game.id] {
        case .starting?:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting…").foregroundStyle(Color.secondaryText)
            }
            .font(.system(size: 13))
            .frame(height: large ? 40 : 34)
        case .running?:
            // Launching.dc.html, "Game is running": Show Game and Stop.
            HStack(spacing: 8) {
                Button("Stop") { library.stop(game) }
                    .buttonStyle(BrandButtonStyle(height: large ? 40 : 34))
                Button("Show Game") { library.showGame(game) }
                    .buttonStyle(BrandButtonStyle(kind: .primary, height: large ? 40 : 34))
            }
        case nil:
            Button {
                library.play(game)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.system(size: large ? 15 : 13, weight: large ? .semibold : .medium))
                    .padding(.horizontal, large ? 12 : 0)
            }
            .buttonStyle(BrandButtonStyle(kind: .primary, height: large ? 40 : 34))
        }
    }
}

/// The icon on a light square of its own main colour.
struct GameIconTile: View {
    let game: GameRecord
    let library: LibraryModel
    let size: CGFloat
    let iconSize: CGFloat
    let radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill((library.tints[game.id] ?? .brand).opacity(0.2))
            .frame(width: size, height: size)
            .overlay {
                if let image = library.icons[game.id] {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: iconSize, height: iconSize)
                        .shadow(color: .black.opacity(0.25), radius: 5, y: 6)
                } else {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: iconSize * 0.5))
                        .foregroundStyle(Color.brand)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Green dot, "Running · 12 min" (Launching.dc.html).
struct RunningBadge: View {
    let since: Date
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.green).frame(width: 8, height: 8)
            Text("Running · \(GameText.duration(max(now, Date()).timeIntervalSince(since)))")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.okText)
    }
}

#Preview {
    LibraryView(components: ComponentsModel(), library: LibraryModel()).frame(width: 1200, height: 780)
}
