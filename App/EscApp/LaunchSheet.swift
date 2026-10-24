import EscAppKit
import SwiftUI

/// Launching.dc.html: "getting the game ready" until the game's window appears, "trying again" when it failed at
/// start, and "nothing helped" when no backend worked.
struct LaunchSheet: View {
    let launch: LibraryModel.Launch
    let library: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch launch.phase {
            case .preparing where !launch.firstTime: starting
            case .preparing: preparing
            case let .retrying(retry): retrying(retry)
            case let .failed(failure): failed(failure)
            }
        }
        .padding(22)
        .frame(width: launch.phase == .preparing && !launch.firstTime ? 380 : 520)
        .background(Color.cardBackground)
        // A sheet is its own view tree: the window's setting doesn't reach it.
        .focusEffectDisabled()
    }

    // MARK: Starting a game that ran before

    /// Its settings are known, so there is nothing to explain: the game, "Starting", a bar and Cancel. The steps
    /// (Windows, graphics) only mean something on the first launch.
    @ViewBuilder private var starting: some View {
        VStack(spacing: 14) {
            if let game = library.game(launch.id) {
                GameIconTile(game: game, library: library, size: 72, iconSize: 54, radius: 18)
            }
            VStack(spacing: 4) {
                Text("Starting \(launch.name)")
                    .font(.system(size: 18, weight: .bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if launch.slow {
                    Text("Taking longer than usual. This can happen after a Mac restart.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ProgressView()
                .progressViewStyle(.linear)
                .tint(.brand)
                .frame(maxWidth: 280)
            Button("Cancel") { library.cancelLaunch() }
                .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
                .keyboardShortcut(.cancelAction)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    // MARK: Getting ready

    @ViewBuilder private var preparing: some View {
        caption(launch.firstTime ? "First launch" : "Starting")
        gameRow(launch.firstTime ? "Getting the game ready for its first launch" : "Getting the game ready")
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

    private var windowsTitle: LocalizedStringKey {
        "Its own \(launch.windows?.displayName ?? WindowsVersion.default.displayName)"
    }

    private var windowsDetail: LocalizedStringKey? {
        guard launch.windows != nil else { return nil }
        if launch.windowsFirstTime { return "once, about 30 s" }
        return launch.windowsState == .done ? "instant" : nil
    }

    // MARK: Trying again

    @ViewBuilder private func retrying(_ retry: LibraryModel.Launch.Retry) -> some View {
        caption("The game failed — EscApp is trying again")
        gameRow(retry.reason == .blankPicture ? "Its window stayed blank"
                    : retry.reason == .noWindow ? "No window after \(retry.seconds) s"
                    : "Closed \(retry.seconds) s after starting")
        Callout(tone: .warning) {
            (retry.reason == .blankPicture && retry.failed == retry.next
                ? Text("Its picture didn't reach the window. Starting it again, drawn another way")
                : otherBackend(retry))
                + Text(verbatim: " ")
                + Text("(attempt \(retry.attempt) of \(retry.total))").font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
        }
        ProgressView()
            .progressViewStyle(.linear)
            .tint(.brand)
        HStack(spacing: 8) {
            Spacer()
            Button("Open Log") { library.openLog(retry.log) }
            Button("Don't Retry") { library.stopRetrying() }
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
        .padding(.top, 8)
    }

    private func otherBackend(_ retry: LibraryModel.Launch.Retry) -> Text {
        Text("\(retry.failed.displayName) doesn't seem to suit this game. Starting with \(retry.next.displayName)")
    }

    // MARK: Nothing helped

    @ViewBuilder private func failed(_ failure: LibraryModel.Launch.Failure) -> some View {
        caption("Didn't start")
        gameRow("Tried: \(failure.tried.map(\.displayName).formatted(.list(type: .and)))")
        Callout(tone: .error) {
            Text(failure.tried.count > 1 ? "The game didn't start with any graphics option." : "The game didn't start.")
                + Text(verbatim: " ") + Self.reason(failure)
        }
        HStack(spacing: 8) {
            Button("Close") { library.cancelLaunch() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Copy Report") { library.copyReport(failure) }
            Button("Show Game Folder") {
                library.showFolder(of: launch.id)
                library.cancelLaunch()
            }
            .buttonStyle(BrandButtonStyle(kind: .primary, height: 32, radius: 8))
            .keyboardShortcut(.defaultAction)
        }
        .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
        .padding(.top, 8)
    }

    /// The most telling reason in plain words; the first-launch cover says it too.
    static func reason(_ failure: LibraryModel.Launch.Failure) -> Text {
        switch failure.problem {
        case let .missingFile(name)?:
            Text("The log says **\(name)** is missing — the game isn't fully installed.")
        case .graphics?:
            Text("Its graphics can't start on this Mac.")
        case .directX12?:
            Text("It needs DirectX 12, which EscApp doesn't support yet.")
        case let .antiCheat(name)?:
            Text("It uses \(name) anti-cheat, which doesn't run on a Mac.")
        case .crash?:
            Text("It crashes while starting.")
        case .needsDisc?:
            Text("It asks for its disc.")
        case .needsSteam?:
            Text("It needs Steam running.")
        case nil:
            if failure.reason == .blankPicture {
                Text("Its window stays blank.")
            } else if case let .closed(code)? = failure.reason {
                Text("It closes right after starting (code \(String(code))).")
            } else {
                Text("Its window never appeared.")
            }
        }
    }

    // MARK: Parts

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(Color.secondaryText)
    }

    private func gameRow(_ hint: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            if let game = library.game(launch.id) {
                GameIconTile(game: game, library: library, size: 44, iconSize: 34, radius: 11)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(launch.name).font(.system(size: 16, weight: .semibold))
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
            }
        }
    }
}

/// The tinted box with an icon: amber for "trying again", red for "nothing helped".
private struct Callout<Content: View>: View {
    enum Tone { case warning, error }

    let tone: Tone
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tone == .warning ? "arrow.clockwise" : "exclamationmark.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tone == .warning ? Color.warnText : Color.danger)
                .frame(width: 18, height: 18)
            content
                .font(.system(size: 14))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(tone == .warning ? Color.warnBackground : Color.errorBackground,
                    in: .rect(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tone == .warning ? Color.warnBorder : Color.errorBorder, lineWidth: 1)
        }
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

/// Launching.dc.html, "it worked": after retries found a backend, which one, and that it is remembered.
struct LearnedToast: View {
    let learned: LibraryModel.Learned
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.newText)
                .frame(width: 28, height: 28)
                .background(Color.newBackground, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(learned.name) started with \(learned.backend.displayName)")
                    .font(.system(size: 14, weight: .semibold))
                Text("Next time it starts this way right away")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
            }
            Spacer(minLength: 16)
            Button("OK", action: dismiss)
                .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: 480)
        .background(Color.cardBackground, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.cardBorder, lineWidth: 1)
        }
        .shadow(color: Color(red: 40 / 255, green: 30 / 255, blue: 20 / 255).opacity(0.12), radius: 9, y: 6)
        .task {
            // It's news, not a question: it goes by itself.
            try? await Task.sleep(for: .seconds(20))
            dismiss()
        }
    }
}
