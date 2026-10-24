import AppKit
import EscAppKit
import SwiftUI
import UniformTypeIdentifiers

/// The main window, laid out as in the design (Main.dc.html in the main-screen canvas): toolbar with search,
/// "Open Game…" and settings; an update strip; the row of stores; "Games" with source filters and order; cover
/// cards; a hint at the bottom.
struct LibraryView: View {
    /// `stores` opens the "Add a Store" window over the library (from Settings, or a "needs Steam" message).
    enum Page: Hashable { case game(GameID), advanced(GameID), stores }

    let components: ComponentsModel
    let library: LibraryModel
    @State private var page: Page?
    @State private var search = ""
    @State private var isTargeted = false
    @State private var addingStore = false
    @State private var deletingStore: Store?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            if case let .game(id)? = page {
                GamePage(id: id, library: library, back: { page = nil }, advanced: { page = .advanced(id) })
            } else if case let .advanced(id)? = page {
                AdvancedPage(id: id, library: library)
            } else {
                if components.catalog?.updateAvailable == true { UpdateStrip(components: components) }
                if library.games.isEmpty && library.installedStores.isEmpty && library.storeInstalls.isEmpty {
                    EmptyLibraryView { addingStore = true }
                } else {
                    LibraryScreen(library: library, search: search, open: { page = .game($0) },
                                  addStore: { addingStore = true }, deleteStore: { deletingStore = $0 })
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
        .overlay {
            // Over the header too: in full screen nothing but the picture and its controls.
            if library.viewing != nil { ScreenshotViewer(library: library) }
        }
        .overlay(alignment: .bottom) {
            if let learned = library.learned {
                LearnedToast(learned: learned) { library.learned = nil }
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: library.learned)
        // While settings are looked for, the launch shows on the cover over the game instead (`TuningCover`).
        .sheet(item: Binding(get: { library.launch?.tuning == nil ? library.launch : nil }, set: {
            if $0 == nil, library.launch?.tuning == nil { library.cancelLaunch() }
        })) { launch in
            LaunchSheet(launch: launch, library: library)
        }
        .sheet(item: Binding(get: { library.deleting }, set: { library.deleting = $0 })) { game in
            DeleteGameSheet(game: game, folderSize: nil, library: library) { _ in library.deleting = nil }
        }
        .confirmationDialog(library.confirmingDelete.map { String(localized: "Delete \($0.name)?") } ?? "",
                            isPresented: Binding(get: { library.confirmingDelete != nil },
                                                 set: { if !$0 { library.confirmingDelete = nil } }),
                            presenting: library.confirmingDelete) { game in
            Button("Move to Trash", role: .destructive) {
                library.deleteStoreGame(game)
                if page == .game(game.id) { page = nil }
            }
        } message: { game in
            Text("""
                The game folder goes to the Trash, and \(game.store?.name ?? "") will show it as not installed \
                (if it's open, it restarts). You can install it again from the store. Saves stay.
                """)
        }
        .sheet(isPresented: $addingStore) { AddStoreSheet(library: library) }
        .sheet(item: $deletingStore) { store in DeleteStoreSheet(store: store, library: library) }
        .installSheet(library)
        .problemSheet(library)
        .onChange(of: library.shownPage, initial: true) {
            guard let shown = library.shownPage else { return }
            library.shownPage = nil
            if shown == .stores {
                page = nil
                addingStore = true
            } else {
                page = shown
            }
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
        // The library's store row shares the toolbar's background, without a line between them.
        HeaderBar(divider: page != nil) {
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
    let addStore: () -> Void
    let deleteStore: (Store) -> Void
    @AppStorage("LibraryOrder") private var order: Order = .recent
    @State private var filter: Filter = .all

    var body: some View {
        VStack(spacing: 0) {
            StoreBar(library: library, showGames: { filter = .store($0) }, add: addStore, remove: deleteStore)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 16)], spacing: 20) {
                        ForEach(shown) { game in
                            GameCard(game: game, library: library) { open(game.id) }
                        }
                    }
                    if shown.isEmpty { emptyText }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 14)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { HintLine(library: library) }
        }
        .onChange(of: library.installedStores) {
            // The chosen store was deleted.
            if case let .store(store) = filter, !showsChip(store) { filter = .all }
        }
    }

    private var emptyText: some View {
        Group {
            if !search.isEmpty {
                Text("No games match “\(search)”.")
            } else {
                Text("Games you install in a store appear here by themselves.")
            }
        }
        .foregroundStyle(Color.secondaryText)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
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
            // A store's filter shows once it is installed or has games (Main.dc.html: "Steam · 1").
            ForEach(Store.allCases.filter(showsChip)) { store in
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

    private func showsChip(_ store: Store) -> Bool {
        library.installedStores.contains(store) || !library.games(from: store).isEmpty
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

#Preview {
    LibraryView(components: ComponentsModel(), library: LibraryModel()).frame(width: 1200, height: 780)
}
