import EscAppKit
import SwiftUI

/// "+" in the store row (AddStore.dc.html): every store, with what it is for, and Install, its progress, or
/// "Installed". It stays open while a store installs, so the progress shows.
struct AddStoreSheet: View {
    let library: LibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Add a Store")
                    .font(.system(size: 15, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(BrandButtonStyle(height: 28, square: true, radius: 8))
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }
            .padding(EdgeInsets(top: 14, leading: 18, bottom: 12, trailing: 14))
            Rectangle().fill(Color.cardBorder).frame(height: 1)
            VStack(spacing: 0) {
                ForEach(Array(Store.allCases.enumerated()), id: \.element) { index, store in
                    if index > 0 { Rectangle().fill(Color.rowDivider).frame(height: 1) }
                    AddStoreRow(store: store, library: library)
                }
            }
            .background(Color.cardBackground)
            Rectangle().fill(Color.cardBorder).frame(height: 1)
            Text("Each store lives in its own Windows and doesn't affect other games.")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 12, leading: 18, bottom: 14, trailing: 18))
        }
        .frame(width: 460)
        .background(Color.toolbarBackground)
        .onAppear { library.refreshStores() }
    }
}

private struct AddStoreRow: View {
    let store: Store
    let library: LibraryModel

    var body: some View {
        HStack(spacing: 14) {
            StoreLogo(store: store, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.name)
                    .font(.system(size: 14, weight: .semibold))
                Text(store.purpose)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var trailing: some View {
        switch library.state(of: store) {
        case .installed:
            // "Установлен": the Russian word agrees with "store", unlike the components' "Installed".
            Label(String(localized: "store.installed", defaultValue: "Installed"), systemImage: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.okText)
        case let .installing(step):
            HStack(spacing: 8) {
                InstallPie(fraction: step.fraction, size: 22, color: .brand)
                if let fraction = step.fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.brand)
            .frame(minWidth: 64, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Installing \(store.name)")
        case .notInstalled:
            Button("Install") { library.installStore(store) }
                .buttonStyle(BrandButtonStyle(height: 28, radius: 8))
        }
    }
}

/// "Delete Steam and All Its Games…" (DeleteStore.dc.html): which games go and how much space comes back. The
/// list scrolls, biggest first, so a store with dozens of games doesn't stretch the window.
struct DeleteStoreSheet: View {
    let store: Store
    let library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var sizes: [GameID: Int64] = [:]

    private var games: [GameRecord] {
        library.games(from: store).sorted { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }
    }

    var body: some View {
        VStack(spacing: 12) {
            StoreLogo(store: store, size: 56)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.danger, in: .circle)
                        .overlay { Circle().strokeBorder(Color.toolbarBackground, lineWidth: 3).padding(-3) }
                        .offset(x: 8, y: 6)
                }
                .padding(.bottom, 4)
            Text("Delete \(store.name) and all its games?")
                .font(.system(size: 15, weight: .bold))
                .multilineTextAlignment(.center)
            Text(lead)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !games.isEmpty { list }
            Text("Saves stay: if you install \(store.name) again, its games pick them up.")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(BrandButtonStyle(fill: true))
                    .keyboardShortcut(.cancelAction)
                Button("Delete") {
                    library.removeStore(store)
                    dismiss()
                }
                .buttonStyle(BrandButtonStyle(kind: .destructive, fill: true))
            }
            .padding(.top, 6)
        }
        .padding(EdgeInsets(top: 24, leading: 22, bottom: 18, trailing: 22))
        .frame(width: 380)
        .background(Color.toolbarBackground)
        .task { await measure() }
    }

    private var lead: String {
        let running = library.runningStores.contains(store)
            ? String(localized: "\(store.name) is running; EscApp closes it first.") + " " : ""
        return running + (games.isEmpty
            ? String(localized: "\(store.name) is removed from this Mac. No games were installed through it.")
            : String(localized: "\(store.name) and the games installed through it are removed from this Mac:"))
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Will be deleted").fontWeight(.semibold)
                Spacer()
                Text(summary).fontWeight(.semibold).monospacedDigit()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.windowBackground)
            Rectangle().fill(Color.cardBorder).frame(height: 1)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(games.enumerated()), id: \.element.id) { index, game in
                        if index > 0 { Rectangle().fill(Color.rowDivider).frame(height: 1) }
                        HStack {
                            Text(game.name).lineLimit(1)
                            Spacer()
                            if let size = sizes[game.id] {
                                Text(size.formatted(.byteCount(style: .file)))
                                    .foregroundStyle(Color.secondaryText)
                                    .monospacedDigit()
                            }
                        }
                        .font(.system(size: 13))
                        .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(Color.cardBackground, in: .rect(cornerRadius: 10, style: .continuous))
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.cardBorder) }
    }

    /// "8 games · 54.5 GB", the size once the folders are measured.
    private var summary: String {
        let count = String(localized: "\(games.count) games")
        guard !sizes.isEmpty else { return count }
        return "\(count) · \(sizes.values.reduce(0, +).formatted(.byteCount(style: .file)))"
    }

    private func measure() async {
        for game in library.games(from: store) {
            let folder = URL(filePath: game.folder, directoryHint: .isDirectory)
            let size = await Task.detached(priority: .utility) { FolderSize.bytes(of: folder) }.value
            sizes[game.id] = size
        }
    }
}

/// How much a folder takes on disk, for the delete sheet.
enum FolderSize {
    static func bytes(of folder: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys))
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
