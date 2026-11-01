import AppKit
import SwiftUI

/// The design draws its own 56-pt header (Main.dc.html, Game.dc.html): traffic lights at x 16 centred in it,
/// then the content. The system toolbar can't look like that (macOS 26 wraps items in glass capsules and draws
/// its own title), so the window gets a transparent title bar, the content runs under it, and the traffic lights
/// are moved to where the design has them.
struct WindowChrome: NSViewRepresentable {
    static let headerHeight: CGFloat = 56

    /// Centre of the close button: (22, 28) in the main window's header; (22, 22) at the top of the Settings
    /// sidebar (Settings.dc.html). The other two follow 20 pt apart.
    var firstLight = CGPoint(x: 22, y: headerHeight / 2)
    /// Size on first open, and the defaults key AppKit saves the frame under (so a saved size wins).
    var initialSize = NSSize(width: 1200, height: 780)
    var frameKey = "NSWindow Frame library"

    func makeNSView(context: Context) -> NSView {
        let view = ChromeView()
        view.chrome = self
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        var chrome = WindowChrome()
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            // AppKit puts the buttons back after resizing and full screen, so place them again each time.
            observers = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                         NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification]
                .map { name in
                    let first = chrome.firstLight
                    return NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                        MainActor.assumeIsolated { ChromeView.placeButtons(in: window, first: first) }
                    }
                }
            Self.placeButtons(in: window, first: chrome.firstLight)
            // First open (nothing saved yet): the design's size. SwiftUI's defaultSize loses to the content's
            // minimum size here, so set it directly.
            if UserDefaults.standard.string(forKey: chrome.frameKey) == nil {
                let size = chrome.initialSize
                // After SwiftUI's own first sizing pass, which would undo it.
                DispatchQueue.main.async {
                    guard window.frame.width < size.width - 50 else { return }
                    window.setContentSize(size)
                    window.center()
                }
            }
        }

        /// Design: three 12-pt dots, 8 pt apart. AppKit's buttons are 14 pt; centring each on the design's dot
        /// keeps them aligned.
        static func placeButtons(in window: NSWindow, first: CGPoint) {
            let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (index, kind) in kinds.enumerated() {
                guard let button = window.standardWindowButton(kind), let container = button.superview else { continue }
                let centreX = first.x + CGFloat(index) * 20
                let centreFromTop = first.y
                let y = container.isFlipped
                    ? centreFromTop - button.frame.height / 2
                    : container.bounds.height - centreFromTop - button.frame.height / 2
                button.setFrameOrigin(NSPoint(x: centreX - button.frame.width / 2, y: y))
            }
        }
    }
}

/// The design's header bar: 56 pt, #FBFAF8, a 1-pt #E4E0D8 line under it, 16-pt gaps, room for the traffic
/// lights. Dragging its empty parts moves the window, like a title bar.
struct HeaderBar<Content: View>: View {
    /// Off over the library's store row, which shares the bar's background (Main.dc.html in the main-screen canvas).
    var divider = true
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 16) {
            // Three 12-pt lights and two 8-pt gaps.
            Color.clear.frame(width: 52, height: 1)
            content
        }
        .padding(.horizontal, 16)
        .frame(height: WindowChrome.headerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.toolbarBackground)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(Color.cardBorder).frame(height: 1) }
        }
        .gesture(WindowDragGesture())
    }
}

/// The design's search box: 260 × 32 (240 plus 10-pt sides), #EFECE7, radius 8, a 14-pt magnifier 8 pt from the text.
struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                .frame(width: 14, height: 14)
            TextField("Search games", text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(.primary)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.secondaryText)
        .padding(.horizontal, 10)
        .frame(width: 260, height: 32)
        .background(Color.chip, in: .rect(cornerRadius: 8, style: .continuous))
    }
}
