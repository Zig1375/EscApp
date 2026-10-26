import EscAppKit
import SwiftUI

/// Launching.dc.html: "starting" until the game's window appears, "trying again" when it failed at
/// start, and "nothing helped" when no backend worked.
struct LaunchSheet: View {
    let launch: LibraryModel.Launch
    let library: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch launch.phase {
            case .preparing: starting
            case let .retrying(retry): retrying(retry)
            case let .failed(failure): failed(failure)
            }
        }
        .padding(22)
        .frame(width: launch.phase == .preparing ? 380 : 520)
        .background(Color.cardBackground)
        // A sheet is its own view tree: the window's setting doesn't reach it.
        .focusEffectDisabled()
    }

    // MARK: Starting

    /// The game, "Starting", a bar and Cancel. The steps behind it (its own Windows, the graphics) meant nothing
    /// to players, on the first launch as much as later ones; the settings search has its own screen.
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
                if let component = launch.component {
                    ComponentStatus(component: component)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else if launch.slow {
                    Text(launch.firstTime ? "The first launch can take up to a minute."
                                          : "Taking longer than usual. This can happen after a Mac restart.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let component = launch.component {
                ComponentBar(component: component).frame(maxWidth: 280)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.brand)
                    .frame(maxWidth: 280)
            }
            Button("Cancel") { library.cancelLaunch() }
                .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
                .keyboardShortcut(.cancelAction)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    // MARK: Trying again

    @ViewBuilder private func retrying(_ retry: LibraryModel.Launch.Retry) -> some View {
        caption("The game failed — EscApp is trying again")
        gameRow(retry.reason == .blankPicture ? "Its window stayed blank"
                    : retry.reason == .noWebGL ? "Its graphics didn't start"
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
            reason(failure.reason)
        }
    }

    /// What the check saw, when the log tells nothing more.
    private static func reason(_ seen: AttemptJudge.Failure?) -> Text {
        switch seen {
        case .blankPicture?: Text("Its window stays blank.")
        case .noWebGL?: Text("Its graphics can't start on this Mac.")
        case let .closed(code)?: Text("It closes right after starting (code \(String(code))).")
        case .noWindow?, nil: Text("Its window never appeared.")
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

/// "Installing components this game needs (1 of 2)" and what it is doing now: "Microsoft Visual C++ 2010:
/// downloading 3 MB of 9 MB", then "…: installing". Players see each thing by its own name, so a minute of
/// waiting on a first launch says what it is for.
struct ComponentStatus: View {
    let component: GameLauncher.Component

    var body: some View {
        VStack(spacing: 2) {
            if component.count > 1 {
                Text("Installing components this game needs (\(component.number) of \(component.count))")
            } else {
                Text("Installing components this game needs")
            }
            switch component.phase {
            case let .downloading(received, total):
                let amounts = (received: received.formatted(.byteCount(style: .file)),
                               total: total.formatted(.byteCount(style: .file)))
                Text("\(component.name): downloading \(amounts.received) of \(amounts.total)")
            case .installing:
                Text("\(component.name): installing…")
            }
        }
    }
}

/// How far the download is, or a running bar while the installer works and can't say.
struct ComponentBar: View {
    let component: GameLauncher.Component
    var height: CGFloat?

    var body: some View {
        Group {
            if case let .downloading(received, total) = component.phase, total > 0 {
                ProgressView(value: Double(min(received, total)), total: Double(total))
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.linear)
        .tint(.brand)
        .frame(height: height)
    }
}
