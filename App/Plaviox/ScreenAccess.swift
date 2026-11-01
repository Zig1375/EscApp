import AppKit
import CoreGraphics
import PlavioxKit
import SwiftUI

/// Screen Recording, which macOS asks for before one app may see another's windows. Plaviox looks at a game's
/// window during a first launch (`WindowPicture`) to tell a working game from a black or frozen one; without the
/// permission it guesses from the window's size and the game's CPU (`FrozenWindow`), and Among Us's frozen black
/// window, with Steam's notice in its corner, needed the picture to be told for sure. Offered once in its own
/// window after setup; Settings › General shows it and asks again.
enum ScreenAccess {
    static let windowID = "screenAccess"
    /// The window has been shown once.
    static let offeredKey = "ScreenAccessOffered"
    /// macOS has shown its own question once; it never shows it again, so later asks open System Settings.
    static let requestedKey = "ScreenAccessRequested"

    static var allowed: Bool { WindowPicture.allowed }

    /// macOS's own question, which it shows only once; it lists Plaviox in System Settings either way.
    static func requestOnce() {
        guard !allowed, !UserDefaults.standard.bool(forKey: requestedKey) else { return }
        UserDefaults.standard.set(true, forKey: requestedKey)
        _ = CGRequestScreenCaptureAccess()
    }

    /// Asks for the steps window from anywhere, the first-launch cover too: that is a plain AppKit window,
    /// outside SwiftUI's scenes, where `openWindow` can't open one. The library window's `ScreenAccessOffer`
    /// opens it, and Plaviox comes forward, so the window is over the cover.
    static let showRequest = Notification.Name("PlavioxShowScreenAccess")

    @MainActor static func show() {
        NSApp.activate()
        NotificationCenter.default.post(name: showRequest, object: nil)
    }

    /// Asks macOS first: that puts Plaviox in the Screen Recording list for this signature. After the permission
    /// was reset, or Plaviox came with another signature, the list had no Plaviox to turn on, or a stale one whose
    /// switch did nothing.
    static func openSystemSettings() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Opens the window once, after the first setup, while the permission isn't given, and whenever a note asks.
struct ScreenAccessOffer: ViewModifier {
    let ready: Bool
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onChange(of: ready, initial: true) {
                let defaults = UserDefaults.standard
                guard ready, !defaults.bool(forKey: ScreenAccess.offeredKey), !ScreenAccess.allowed else { return }
                defaults.set(true, forKey: ScreenAccess.offeredKey)
                openWindow(id: ScreenAccess.windowID)
            }
            // "Allow…" in a note about the permission (`ScreenAccess.show`).
            .onReceive(NotificationCenter.default.publisher(for: ScreenAccess.showRequest)) { _ in
                openWindow(id: ScreenAccess.windowID)
            }
    }
}

/// The once-only window, in short steps: what it is for, then where to turn it on. Each step opens with a
/// picture of what it is about, a game window Plaviox looks at, then the switch in System Settings, so the words
/// can stay short: a first version said everything in four paragraphs, a second floated a lone icon over them.
struct ScreenAccessWindow: View {
    enum Step { case ask, settings }
    /// Snapshots draw the pictures as they end up, not as their animation starts.
    static var stillPictures = false

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var allowed: Bool
    @State private var step: Step
    private let follows: Bool

    /// `allowed` and `step` are for snapshots (`ScreenAccessSnapshots`); the window itself follows the permission.
    /// Opened again from Settings after macOS has asked once, it starts on the System Settings step.
    init(step: Step? = nil, allowed: Bool? = nil) {
        let asked = UserDefaults.standard.bool(forKey: ScreenAccess.requestedKey)
        _step = State(initialValue: step ?? (asked ? .settings : .ask))
        _allowed = State(initialValue: allowed ?? ScreenAccess.allowed)
        follows = allowed == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if allowed {
                    SettingsSwitchPicture(on: true, animated: false)
                } else if step == .ask {
                    WatchedWindowPicture()
                } else {
                    SettingsSwitchPicture(on: true, animated: true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 184)
            .background(Color.cardBackground)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.cardBorder).frame(height: 1) }

            VStack(spacing: 10) {
                if allowed {
                    texts("Plaviox can see game windows",
                          "Thank you. First launches will now find the right settings more surely.")
                } else if step == .ask {
                    texts("Let Plaviox see game windows",
                          "So Plaviox can tell when a game shows only a black screen, and fix it by itself.")
                    Text("""
                        Plaviox only looks at games it starts. Nothing is recorded or sent. Without it, Plaviox still \
                        works, just less accurately.
                        """)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryText)
                } else {
                    texts("Turn on Plaviox in System Settings",
                          "Find Plaviox in the list and switch it on. If macOS offers to reopen Plaviox, agree.")
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 36)
            .padding(.top, 22)

            buttons
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 20)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.windowBackground)
        .focusEffectDisabled()
        .animation(.easeInOut(duration: 0.25), value: step)
        .animation(.easeInOut(duration: 0.25), value: allowed)
        // System Settings is where the switch is: the window follows it while it stays open.
        .task {
            while follows, !Task.isCancelled {
                allowed = ScreenAccess.allowed
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func texts(_ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(body)
                .font(.system(size: 13))
                .lineSpacing(2)
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 10) {
            if allowed {
                Button("Done") { dismissWindow(id: ScreenAccess.windowID) }
                    .buttonStyle(BrandButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .frame(maxWidth: .infinity)
            } else if step == .ask {
                Button("Not Now") { dismissWindow(id: ScreenAccess.windowID) }
                    .buttonStyle(BrandButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Allow") {
                    ScreenAccess.requestOnce()
                    step = .settings
                }
                .buttonStyle(BrandButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Later") { dismissWindow(id: ScreenAccess.windowID) }
                    .buttonStyle(BrandButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Open System Settings") { ScreenAccess.openSystemSettings() }
                    .buttonStyle(BrandButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A small game window gone black, with Plaviox's viewfinder closing in on it: what the permission is for.
private struct WatchedWindowPicture: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focused = ScreenAccessWindow.stillPictures

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.22)).frame(width: 6) }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: 16)
                .background(Color(white: 0.16))
                Color.black
            }
            .frame(width: 176, height: 108)
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.12))
            }
            Viewfinder()
                .stroke(Color.brand, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .frame(width: 204, height: 136)
                .scaleEffect(focused || reduceMotion ? 1 : 1.12)
                .opacity(focused || reduceMotion ? 1 : 0)
        }
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(.spring(duration: 0.7, bounce: 0.25).delay(0.2)) { focused = true }
        }
    }
}

/// The four corners of a camera's viewfinder.
private struct Viewfinder: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = min(rect.width, rect.height) * 0.2
        var path = Path()
        for (corner, across, down) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0),
                                 (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
                                 (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + down * arm))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + across * arm, y: corner.y))
        }
        return path
    }
}

/// Plaviox's row in System Settings with its switch, the one thing to do there; it flips on while shown.
private struct SettingsSwitchPicture: View {
    let on: Bool
    let animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flipped = ScreenAccessWindow.stillPictures

    private var isOn: Bool { animated && !reduceMotion ? flipped : on }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            Text(verbatim: "Plaviox")
                .font(.system(size: 14, weight: .medium))
            Spacer()
            Capsule()
                .fill(isOn ? Color.accentColor : Color.track)
                .frame(width: 38, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).padding(2).shadow(radius: 1, y: 0.5)
                }
        }
        .padding(.horizontal, 16)
        .frame(width: 280, height: 58)
        .background(Color.windowBackground, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.cardBorder) }
        .accessibilityHidden(true)
        .task {
            guard animated, !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.spring(duration: 0.35)) { flipped = true }
        }
    }
}

/// Settings › General: whether Plaviox may see game windows. "Allow…" opens the window with its steps: a bare
/// System Settings page left the player guessing what to do there.
struct ScreenAccessRow: View {
    @State private var allowed = ScreenAccess.allowed
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("See game windows")
                Text("Helps Plaviox spot a game stuck on a black screen. Nothing is recorded or sent.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if allowed {
                Text("Allowed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.okText)
            } else {
                Button("Allow…") { openWindow(id: ScreenAccess.windowID) }
                    .buttonStyle(CompactButtonStyle(kind: .primary))
                    .fixedSize()
            }
        }
        .task {
            while !Task.isCancelled {
                allowed = ScreenAccess.allowed
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

#if DEBUG
import ScreenCaptureKit

/// Debug builds only: `open Plaviox.app --args -screenAccessReport <file>` writes what macOS answers about the
/// permission, by its preflight and by ScreenCaptureKit, and quits. Opened through `open`, the app itself is the
/// one asking, not the shell that started it.
@MainActor
enum ScreenAccessReport {
    static func runIfAsked() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-screenAccessReport"), index + 1 < arguments.count else { return }
        let file = URL(filePath: arguments[index + 1])
        // Detached, not a plain Task: ScreenCaptureKit's answer isn't Sendable, so awaiting it on this @MainActor
        // enum is an error under the SDK the release runners have, and nothing below needs the main actor.
        Task.detached {
            var lines = ["preflight \(CGPreflightScreenCaptureAccess())"]
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                lines.append("screencapturekit ok, \(content.windows.count) windows")
            } catch {
                lines.append("screencapturekit error \(error)")
            }
            try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            exit(0)
        }
    }
}

/// Debug builds only: `Plaviox -snapshotScreenAccess <folder>` draws each step of the window, and the game page's
/// and first-launch screen's notes (`ScreenAccessNotes`), light and dark, into
/// PNGs in the app's language (`-AppleLanguages (ru)`) and quits: the later steps can't be reached without
/// answering macOS's own question.
@MainActor
enum ScreenAccessSnapshots {
    static func runIfAsked() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-snapshotScreenAccess"), index + 1 < arguments.count else { return }
        let folder = URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        ScreenAccessWindow.stillPictures = true
        let shots: [(String, AnyView)] = [
            ("1-ask", AnyView(ScreenAccessWindow(step: .ask, allowed: false))),
            ("2-settings", AnyView(ScreenAccessWindow(step: .settings, allowed: false))),
            ("3-done", AnyView(ScreenAccessWindow(step: .settings, allowed: true))),
            // The game page's line and the first-launch screen's warning, at their widths there.
            ("4-note", AnyView(ScreenAccessNote(allowed: false).padding(16).frame(width: 520)
                .background(Color.windowBackground))),
            ("5-warning", AnyView(ScreenAccessWarning(allowed: false).padding(24).frame(width: 600)
                .background(Color.cardBackground))),
        ]
        for (name, view) in shots {
            for scheme in [ColorScheme.light, .dark] {
                let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
                renderer.scale = 2
                guard let tiff = renderer.nsImage?.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else { continue }
                let file = "\(language)-\(name)-\(scheme == .dark ? "dark" : "light").png"
                try? png.write(to: folder.appending(path: file))
            }
        }
        exit(0)
    }
}
#endif
