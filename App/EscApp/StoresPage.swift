import EscAppKit
import SwiftUI

/// Stores.dc.html: what each store's client is for, and installing, opening or removing it.
struct StoresPage: View {
    let library: LibraryModel
    @State private var removing: Store?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Stores")
                        .font(.system(size: 24, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Text("""
                        Optional. Many games from Steam, Epic and other stores need their client. Games from discs, \
                        archives and GOG installers work without a store.
                        """)
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .foregroundStyle(Color.secondaryText)
                        .frame(maxWidth: 760, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    ForEach(Array(Store.allCases.enumerated()), id: \.element) { index, store in
                        if index > 0 { Rectangle().fill(Color.rowDivider).frame(height: 1) }
                        StoreRow(store: store, library: library) { removing = store }
                    }
                }
                .background(Color.cardBackground, in: .rect(cornerRadius: 14, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cardBorder) }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Stores")
                Text("Each store lives in its own Windows and doesn't affect other games.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { library.refreshStores() }
        .confirmationDialog(removing.map { String(localized: "Remove \($0.name)?") } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { store in
            Button("Remove", role: .destructive) { library.removeStore(store) }
        } message: { store in
            Text("\(store.name) and the games installed through it are removed from this Mac. Saves stay.")
        }
    }
}

private struct StoreRow: View {
    let store: Store
    let library: LibraryModel
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            StoreLogo(store: store)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.name)
                    .font(.system(size: 15, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder private var trailing: some View {
        switch library.state(of: store) {
        case .installed:
            // "Установлен": the Russian word agrees with "store", unlike the components' "Installed".
            Label(String(localized: "store.installed", defaultValue: "Installed"), systemImage: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.okText)
            Button("Remove…", action: remove)
                .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
            Button("Open \(store.name)") { library.openStore(store) }
                .buttonStyle(BrandButtonStyle(kind: .primary, height: 32, radius: 8))
        case let .installing(step):
            StoreProgress(fraction: fraction(step))
                .accessibilityLabel("Installing \(store.name)")
            Button("Cancel") { library.cancelStoreInstall(store) }
                .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
        case .notInstalled:
            Button("Install") { library.installStore(store) }
                .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
        }
    }

    private var detail: String {
        switch library.state(of: store) {
        case .installed:
            return String(localized: "Games from your \(store.name) library appear in EscApp by themselves")
        case let .installing(.downloading(received, total?)):
            return String(localized: "Installing · \(megabytes(received)) of \(megabytes(total))")
        case let .installing(.updating(received?, total?)):
            let (done, all) = (megabytes(received * 1024), megabytes(total * 1024))
            return String(localized: "Downloading \(store.name) · \(done) of \(all)")
        case .installing(.updating):
            return String(localized: "Downloading \(store.name)…")
        case .installing:
            return String(localized: "Installing…")
        case .notInstalled:
            switch store {
            case .steam: return String(localized: "Games from your Steam library appear in EscApp by themselves")
            case .epic: return String(localized: "Needed for Epic games")
            case .gog: return String(localized: "Usually not needed for GOG games: their installers work by themselves")
            case .eaApp: return String(localized: "Needed for EA games")
            case .ubisoft: return String(localized: "Needed for Ubisoft games")
            }
        }
    }

    private func fraction(_ step: StoreClient.Step) -> Double? {
        switch step {
        case let .downloading(received, total?), let .updating(received?, total?):
            Double(received) / Double(max(total, 1))
        default:
            nil
        }
    }

    private func megabytes(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}

/// 160 × 6, rounded, the amber fill; sliding when how far isn't known.
private struct StoreProgress: View {
    let fraction: Double?

    var body: some View {
        Group {
            if let fraction {
                Capsule()
                    .fill(Color.track)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.brand).frame(width: 160 * min(max(fraction, 0.02), 1))
                    }
            } else {
                ProgressView().progressViewStyle(.linear).tint(Color.brand)
            }
        }
        .frame(width: 160, height: 6)
    }
}

/// The store's square: its colour and initials (the design's placeholders for the real logos).
struct StoreLogo: View {
    let store: Store
    var size: CGFloat = 48

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4, style: .continuous)
            .fill(store.logoColor)
            .frame(width: size, height: size)
            .overlay {
                Text(store.initials)
                    .font(.system(size: size * 0.31, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

extension Store {
    var initials: String {
        switch self {
        case .steam: "St"
        case .epic: "Ep"
        case .gog: "GG"
        case .eaApp: "EA"
        case .ubisoft: "Ub"
        }
    }

    /// Brand colours, the same in light and dark.
    var logoColor: Color {
        switch self {
        case .steam: Color(red: 0x1B / 255, green: 0x28 / 255, blue: 0x38 / 255)
        case .epic: Color(red: 0x2A / 255, green: 0x2A / 255, blue: 0x2A / 255)
        case .gog: Color(red: 0x5C / 255, green: 0x2D / 255, blue: 0x82 / 255)
        case .eaApp: Color(red: 0xC2 / 255, green: 0x27 / 255, blue: 0x2D / 255)
        case .ubisoft: Color(red: 0x1F / 255, green: 0x4A / 255, blue: 0xA8 / 255)
        }
    }

    /// The label on a game card (Main.dc.html: "Steam", "GOG Galaxy").
    var pillColors: (background: Color, text: Color) {
        switch self {
        case .steam: (Color("StorePillSteam"), Color("StorePillTextSteam"))
        case .epic: (Color("StorePillEpic"), Color("StorePillTextEpic"))
        case .gog: (Color("StorePillGog"), Color("StorePillTextGog"))
        case .eaApp: (Color("StorePillEa"), Color("StorePillTextEa"))
        case .ubisoft: (Color("StorePillUbisoft"), Color("StorePillTextUbisoft"))
        }
    }
}
