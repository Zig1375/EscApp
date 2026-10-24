import AppKit
import EscAppKit
import SwiftUI

/// Covers every screen while a first launch looks for its settings (FirstRun.dc.html, "checking"). The game's
/// windows open under it, so a failing attempt doesn't flash them in the player's face; once an attempt works the
/// cover goes and the game comes to the front.
///
/// An ordinary window rather than one above everything: a search can take minutes, and the Mac stays usable.
@MainActor
final class TuningCover {
    private var windows: [NSWindow] = []

    func update(showing: Bool, library: LibraryModel) {
        if !showing {
            windows.forEach { $0.orderOut(nil) }
            windows = []
            return
        }
        guard windows.isEmpty else { return }
        let main = NSScreen.main ?? NSScreen.screens.first
        for screen in NSScreen.screens {
            let window = CoverWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered,
                                     defer: false)
            window.isReleasedWhenClosed = false
            // An ordinary window: the player can switch to other apps meanwhile (⌘-Tab, the Dock), and EscApp,
            // brought forward again whenever an attempt's window appears, keeps it over the game.
            window.level = .normal
            window.collectionBehavior = [.fullScreenAuxiliary]
            window.backgroundColor = NSColor(named: "WindowBackground") ?? .windowBackgroundColor
            window.isOpaque = true
            window.hasShadow = false
            window.setFrame(screen.frame, display: false)
            if screen == main {
                window.contentView = NSHostingView(rootView: TuningScreen(library: library))
            }
            windows.append(window)
        }
        for window in windows where window.contentView is NSHostingView<TuningScreen> {
            window.makeKeyAndOrderFront(nil)
        }
        windows.forEach { $0.orderFrontRegardless() }
        NSApp.activate()
    }
}

/// Borderless windows can't take the keyboard by default; this one has buttons and Esc.
private final class CoverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The card in the middle of the cover.
/// Simple by default: what is happening, in plain words, with a picture and a bar. "Details" shows every step and
/// attempt, and is remembered for players who want to watch.
struct TuningScreen: View {
    let library: LibraryModel
    @AppStorage("TuningDetails") private var details = false

    var body: some View {
        ZStack {
            Color.windowBackground.ignoresSafeArea()
            if let launch = library.launch, let tuning = launch.tuning {
                if case let .failed(failure) = launch.phase {
                    TuningFailedCard(launch: launch, failure: failure, library: library)
                        .frame(width: 620)
                } else if let ready = tuning.ready {
                    TuningReadyCard(launch: launch, ready: ready, library: library)
                        .frame(width: 560)
                } else if details {
                    TuningCard(launch: launch, tuning: tuning, library: library) { details = false }
                        .frame(width: 600)
                } else {
                    SimpleTuningCard(launch: launch, tuning: tuning, library: library) { details = true }
                        .frame(width: 600)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: details)
        .focusEffectDisabled()
    }
}

private struct TuningCard: View {
    let launch: LibraryModel.Launch
    let tuning: LibraryModel.Launch.Tuning
    let library: LibraryModel
    let simpler: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("First launch · checking")
                    .font(.system(size: 12, weight: .bold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(Color.secondaryText)
                Spacer()
                Button("Hide Details", action: simpler)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.brand)
            }
            HStack(spacing: 14) {
                if let game = library.game(launch.id) {
                    GameIconTile(game: game, library: library, size: 64, iconSize: 46, radius: 14)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Finding settings for \(launch.name)")
                        .font(.system(size: 19, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Text("This is needed once, usually under a minute").modifier(TuningHint())
                }
            }
            TuningStep(state: .done, title: "Looked at the game's files",
                       detail: filesDetail.map { Text(verbatim: $0) })
            TuningStep(state: launch.windowsState == .done ? .done : .now, title: windowsTitle, detail: nil)
            if launch.windowsState == .done { attempts }
            Text("""
                The game's window stays hidden while EscApp checks: it may open and close a few times. Once \
                something works, the game appears by itself.
                """)
                .modifier(TuningHint())
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.windowBackground, in: .rect(cornerRadius: 10, style: .continuous))
            HStack(spacing: 8) {
                Button("Cancel") { library.cancelLaunch() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Choose Settings Myself") { library.chooseSettingsMyself() }
                Button("Don't Check, Just Start") { library.stopRetrying() }
            }
            .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
        }
        .padding(24)
        .background {
            // The shadow on the card's shape only: on the whole view every row and line of text would cast one.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.cardBackground)
                .shadow(color: Color(red: 40 / 255, green: 30 / 255, blue: 20 / 255).opacity(0.12), radius: 17, y: 14)
        }
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.cardBorder) }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var attempts: some View {
        VStack(alignment: .leading, spacing: 10) {
            TuningStep(state: .now, title: "Trying to start the game",
                       detail: Text("Checking that its window opens and the game keeps running"))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(tuning.failed.enumerated()), id: \.offset) { _, failed in
                    TryRow(state: .fail, text: failedText(failed), note: note(failed))
                }
                TryRow(state: .now, text: currentText, note: nil)
                // FirstRun.dc.html's bar: how much of the check the window has held.
                Capsule()
                    .fill(Color.track)
                    .frame(height: 6)
                    .overlay(alignment: .leading) {
                        GeometryReader { bar in
                            Capsule().fill(Color.brand)
                                .frame(width: bar.size.width * fraction)
                        }
                    }
                    .animation(.linear(duration: 0.9), value: fraction)
                    .accessibilityElement()
                    .accessibilityLabel("Checking \(tuning.currentBackend.displayName)")
                    .accessibilityValue(Text(fraction.formatted(.percent.precision(.fractionLength(0)))))
            }
            .padding(.leading, 34)
        }
    }

    private var fraction: Double {
        tuning.held.map { min(Double($0) / Double(max(tuning.needed, 1)), 1) } ?? 0
    }

    private var filesDetail: String? {
        guard let info = library.infos[launch.id] else { return nil }
        let api: String? = switch info.directX.max() {
        case .legacy?: "DirectDraw"
        case .d3d9?: "DirectX 9"
        case .d3d11?: "DirectX 11"
        case .d3d12?: "DirectX 12"
        case nil: nil
        }
        let bits = info.format == .pe64 ? String(localized: "64-bit") : String(localized: "32-bit")
        return ([api, bits] as [String?]).compactMap(\.self).joined(separator: " · ")
    }

    private var windowsTitle: LocalizedStringKey {
        let name = launch.windows?.displayName ?? WindowsVersion.default.displayName
        return launch.windowsState == .done ? "Prepared \(name)" : "Preparing \(name)"
    }

    private var currentText: Text {
        let name = Text(tuning.currentBackend.displayName).fontWeight(.semibold)
        if let held = tuning.held {
            return name + Text(verbatim: " — ") + Text("the window opened, checking \(held) of \(tuning.needed) s")
        }
        return name + Text(verbatim: " — ") + Text("starting…")
    }

    private func failedText(_ failed: LibraryModel.Launch.Tuning.Try) -> Text {
        let name = Text(failed.backend.displayName).fontWeight(.semibold)
        let what: Text = failed.reason == .blankPicture ? Text("the window stayed blank")
            : failed.reason == .noWindow ? Text("no window after \(failed.seconds) s")
            : Text("closed after \(failed.seconds) s")
        return name + Text(verbatim: " — ") + what
    }

    private func note(_ failed: LibraryModel.Launch.Tuning.Try) -> LocalizedStringKey? {
        switch failed.problem {
        case .graphics?: "graphics error"
        case .crash?: "crashed"
        case let .missingFile(name)?: "\(name) is missing"
        default: nil
        }
    }
}

/// FirstRun.dc.html's step: a round mark, then the text and a grey line under it.
private struct TuningStep: View {
    let state: TryRow.State
    let title: LocalizedStringKey
    let detail: Text?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TryMark(state: state, size: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14))
                if let detail { detail.modifier(TuningHint()) }
            }
        }
    }
}

/// One attempt: grey for one that didn't work, amber-edged for the one running.
private struct TryRow: View {
    enum State { case done, now, fail }

    let state: State
    let text: Text
    let note: LocalizedStringKey?

    var body: some View {
        HStack(spacing: 10) {
            TryMark(state: state, size: 18)
            text.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            if let note { Text(note).modifier(TuningHint()) }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(state == .now ? Color.warnBackground : Color.windowBackground,
                    in: .rect(cornerRadius: 10, style: .continuous))
        .overlay {
            if state == .now {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.warnBorder)
            }
        }
    }
}

private struct TryMark: View {
    let state: TryRow.State
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(background)
            switch state {
            case .done: Image(systemName: "checkmark").font(.system(size: size * 0.45, weight: .bold))
            case .now: ProgressView().controlSize(.mini)
            case .fail: Image(systemName: "xmark").font(.system(size: size * 0.45, weight: .bold))
            }
        }
        .foregroundStyle(foreground)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var background: Color {
        switch state {
        case .done: .newBackground
        case .now: .navSelected
        case .fail: .errorBackground
        }
    }

    private var foreground: Color {
        switch state {
        case .done: .newText
        case .now: .brand
        case .fail: .danger
        }
    }
}

struct TuningHint: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12))
            .lineSpacing(2)
            .foregroundStyle(Color.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
