import MagicKettleKit
import SwiftUI

/// The row of stores under the toolbar (Main.dc.html in the main-screen canvas): one logo per installed store,
/// a dashed "+" while some are left to add. A click opens the store; its menu has the rest. The stores used to be
/// cards among the games and a screen of their own, where players didn't look for them.
struct StoreBar: View {
    let library: LibraryModel
    let showGames: (Store) -> Void
    let add: () -> Void
    let remove: (Store) -> Void

    var body: some View {
        HStack(spacing: 18) {
            ForEach(shown) { store in
                StoreButton(store: store, library: library, showGames: { showGames(store) },
                            remove: { remove(store) })
            }
            if Store.allCases.contains(where: { library.state(of: $0) == .notInstalled }) {
                AddStoreButton(action: add)
            }
            if shown.isEmpty {
                Text("""
                    Add Steam, Epic or another store, and its games appear here.
                    Games from discs and installers work without a store.
                    """)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 16, leading: 24, bottom: 22, trailing: 24))
        .background(Color.toolbarBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.cardBorder).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stores")
    }

    private var shown: [Store] {
        Store.allCases.filter { library.state(of: $0) != .notInstalled || library.removingStores.contains($0) }
    }
}

/// One store's logo: green ring and dot while it runs, a marching dashed ring while it starts or stops, and
/// iOS's install look while it installs (darkened, a circle filling up).
private struct StoreButton: View {
    let store: Store
    let library: LibraryModel
    let showGames: () -> Void
    let remove: () -> Void
    @State private var isHovered = false

    private enum Phase { case idle, opening, running, stopping, installing(Double?), removing }

    private var phase: Phase {
        if library.removingStores.contains(store) { return .removing }
        if case let .installing(step) = library.state(of: store) { return .installing(step.fraction) }
        if library.stoppingStores.contains(store) { return .stopping }
        if library.runningStores.contains(store) { return .running }
        if library.openingStores.contains(store) { return .opening }
        return .idle
    }

    var body: some View {
        Button { open() } label: {
            StoreLogo(store: store, size: 64)
                .overlay { busyOverlay }
                .shadow(color: .black.opacity(isHovered ? 0.22 : 0.16), radius: isHovered ? 7 : 1, y: isHovered ? 6 : 1)
                .offset(y: isHovered && canOpen ? -1 : 0)
        }
        .buttonStyle(.plain)
        .overlay { ring }
        .overlay(alignment: .bottom) { dot.offset(y: 12) }
        .overlay(alignment: .topTrailing) { quitBadge.offset(x: 8, y: -8) }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .help(Text(tooltip))
        .accessibilityLabel(Text(store.name))
        .accessibilityValue(Text(status ?? ""))
        .contextMenu { menu }
    }

    private var canOpen: Bool {
        switch phase {
        case .idle, .running: true
        default: false
        }
    }

    private func open() {
        guard canOpen else { return }
        library.openStore(store)
    }

    @ViewBuilder private var busyOverlay: some View {
        switch phase {
        case let .installing(fraction):
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.55))
                .overlay { InstallPie(fraction: fraction, size: 44, color: .white) }
        case .removing:
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.55))
                .overlay { ProgressView().controlSize(.small).tint(.white) }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var ring: some View {
        switch phase {
        case .running:
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.green, lineWidth: 2)
                .padding(-4)
                .allowsHitTesting(false)
        case .opening, .stopping:
            MarchingRing(cornerRadius: 21)
                .padding(-5)
                .allowsHitTesting(false)
        default:
            EmptyView()
        }
    }

    /// Quit on hover: the client's close button only hides its window, as it would go to the tray on Windows, and
    /// Magic Kettle quits it a while later; a player who closed Epic's window saw it linger with no way to quit but the
    /// context menu. Not while one of its games runs, which quitting would end.
    @ViewBuilder private var quitBadge: some View {
        if case .running = phase, isHovered, !library.isPlaying(from: store) {
            Button { library.quitStore(store) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.black.opacity(0.7)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(Text("Quit \(store.name)"))
            .accessibilityLabel(Text("Quit \(store.name)"))
            .transition(.opacity)
        }
    }

    @ViewBuilder private var dot: some View {
        switch phase {
        case .running:
            Circle().fill(Color.green).frame(width: 6, height: 6)
        case .opening:
            PulsingDot()
        default:
            EmptyView()
        }
    }

    /// "Running", "Starting…", "Installing · 40%": the tooltip after the name, and the menu's heading.
    private var status: String? {
        switch phase {
        case .idle: nil
        // "Запущен": the Russian word agrees with the store, like "store.installed".
        case .running: String(localized: "store.running", defaultValue: "Running")
        case .opening: String(localized: "store.starting", defaultValue: "Starting…")
        case .stopping: String(localized: "store.stopping", defaultValue: "Stopping…")
        case .removing: String(localized: "store.removing", defaultValue: "Deleting…")
        case let .installing(fraction?):
            String(localized: "Installing · \(fraction.formatted(.percent.precision(.fractionLength(0))))")
        case .installing(nil): String(localized: "Installing…")
        }
    }

    private var tooltip: String {
        status.map { "\(store.name) · \($0)" } ?? store.name
    }

    @ViewBuilder private var menu: some View {
        Section(tooltip) {
            switch phase {
            case .installing:
                Button("Cancel Installation", role: .destructive) { library.cancelStoreInstall(store) }
            case .removing:
                EmptyView()
            default:
                let running = library.runningStores.contains(store)
                Button(running ? "Show \(store.name)" : "Open \(store.name)", action: open)
                    .disabled(!canOpen)
                if running {
                    // Closing a client's window only hides it, and on a Mac there is no tray icon to quit it from.
                    // Not while one of its games runs, which quitting would end.
                    Button("Quit \(store.name)") { library.quitStore(store) }
                        .disabled(library.stoppingStores.contains(store) || library.isPlaying(from: store))
                }
                Divider()
                Button("Show Only Its Games", action: showGames)
                Button("Refresh Game List") { library.refreshStores() }
                Divider()
                Button("Delete \(store.name) and All Its Games…", role: .destructive, action: remove)
                    .disabled(library.isPlaying(from: store))
            }
        }
    }
}

/// The dashed "+" at the end of the row.
private struct AddStoreButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isHovered ? Color.brand.opacity(0.07) : .clear)
                .strokeBorder(isHovered ? Color.brand : Color.buttonBorder,
                              style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(isHovered ? Color.brand : Color.secondaryText)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help("Add a Store")
        .accessibilityLabel("Add a Store")
    }
}

/// iOS's download circle: a ring, and a pie inside it filling clockwise. Without a fraction (the store's own
/// setup is running and says nothing) a quarter of the ring goes round.
struct InstallPie: View {
    let fraction: Double?
    var size: CGFloat = 44
    var color: Color = .white
    @State private var spins = false

    var body: some View {
        let line = max(2, size / 15)
        ZStack {
            if let fraction {
                Circle().strokeBorder(color, lineWidth: line)
                PieSlice(fraction: min(max(fraction, 0), 1))
                    .fill(color)
                    .padding(line * 1.9)
                    .animation(.easeOut(duration: 0.3), value: fraction)
            } else {
                Circle().strokeBorder(color.opacity(0.35), lineWidth: line)
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .padding(line / 2)
                    .rotationEffect(.degrees(spins ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spins)
                    .onAppear { spins = true }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct PieSlice: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard fraction > 0 else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2, startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// An amber dashed ring whose dashes run round: the store was asked to start or stop and hasn't yet.
private struct MarchingRing: View {
    let cornerRadius: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 18
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.brand, style: StrokeStyle(lineWidth: 2, dash: [5, 4], dashPhase: -phase))
        }
    }
}

private struct PulsingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.brand)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.25 : 1)
            .animation(.easeInOut(duration: 0.45).repeatForever(), value: dim)
            .onAppear { dim = true }
    }
}

/// The store's square: its logo in white on its brand colour. The logos are from Simple Icons (CC0); the marks
/// themselves belong to their owners and only name the store, as in any launcher.
struct StoreLogo: View {
    let store: Store
    var size: CGFloat = 48

    var body: some View {
        // Steam's navy and Epic's charcoal vanished on the dark window: a lighter top and a light edge, as on
        // macOS app icons, lift every tile off the background without changing the brand colours.
        RoundedRectangle(cornerRadius: size / 4, style: .continuous)
            .fill(LinearGradient(colors: [store.logoColor.mix(with: .white, by: 0.16), store.logoColor],
                                 startPoint: .top, endPoint: .bottom))
            .strokeBorder(.white.opacity(0.18), lineWidth: max(1, size / 48))
            .frame(width: size, height: size)
            .overlay {
                (store.logoAsset.map { Image($0) } ?? Image(systemName: "bag.fill"))
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .padding(size * 0.2)
            }
            .accessibilityHidden(true)
    }
}

/// The store logos fanned like cards, so it reads as "the stores" at a glance.
struct StoreStack: View {
    var size: CGFloat = 18

    var body: some View {
        HStack(spacing: -size * 0.4) {
            ForEach(Store.allCases.prefix(3), id: \.self) { store in
                StoreLogo(store: store, size: size)
                    .overlay {
                        RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                            .strokeBorder(Color.cardBackground, lineWidth: 1.5)
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

extension StoreClient.Step {
    /// How far a download is, when the store says.
    var fraction: Double? {
        switch self {
        case let .downloading(received, total?), let .updating(received?, total?):
            Double(received) / Double(max(total, 1))
        default:
            nil
        }
    }
}

/// How a store looks in the app. A store added to MagicKettleKit (`Store.allCases`) adds its case here, with its logo
/// in the asset catalog; until then it shows with a plain bag.
extension Store {
    /// What the store is for, in the "Add a Store" window.
    var purpose: String {
        switch self {
        case .steam: String(localized: "Games from your Steam library appear in Magic Kettle by themselves")
        case .epic: String(localized: "Needed for Epic games")
        default: ""
        }
    }

    var logoAsset: String? {
        switch self {
        case .steam: "StoreSteam"
        case .epic: "StoreEpic"
        default: nil
        }
    }

    /// Brand colours, the same in light and dark.
    var logoColor: Color {
        switch self {
        case .steam: Color(red: 0x1B / 255, green: 0x28 / 255, blue: 0x38 / 255)
        case .epic: Color(red: 0x2A / 255, green: 0x2A / 255, blue: 0x2A / 255)
        default: .gray
        }
    }
}
