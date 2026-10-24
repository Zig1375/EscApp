import AppKit
import EscAppKit
import SwiftUI

/// Game.dc.html's "Screenshots": three pictures and "N more", or up to four, with "All Screenshots". For now only
/// a Steam game has any, from its store page (`SteamScreenshots`); for other games the section isn't shown.
struct ScreenshotsSection: View {
    let game: GameRecord
    let shots: [SteamScreenshots.Shot]
    let library: LibraryModel
    /// Opens the viewer at a picture; it covers the whole window (`ScreenshotViewer`).
    let open: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                SectionTitle(text: "Screenshots")
                Text("\(shots.count) · from the Steam store")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
                Spacer()
                Button("All Screenshots") { open(0) }
                    .buttonStyle(BrandButtonStyle(height: 26, small: true, radius: 8))
            }
            grid
        }
    }

    private var grid: some View {
        let more = shots.count > 4
        let shown = Array(shots.prefix(more ? 3 : 4).enumerated())
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            ForEach(shown, id: \.element.id) { index, shot in
                Button { open(index) } label: {
                    ShotTile(shot: shot, appID: game.storeID ?? "", paths: library.paths)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Screenshot \(index + 1)")
            }
            if more {
                Button { open(3) } label: {
                    Color.chip
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .overlay {
                            Text("\(shots.count - 3) more")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.secondaryText)
                        }
                        .clipShape(.rect(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.buttonBorder)
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The game's screenshots: those kept from last time at once, then fresh ones. None for a game not from Steam.
    static func load(for game: GameRecord, paths: AppPaths, into shots: Binding<[SteamScreenshots.Shot]>) async {
        guard game.store == .steam, let appID = game.storeID else {
            shots.wrappedValue = []
            return
        }
        shots.wrappedValue = SteamScreenshots.cached(appID: appID, paths: paths) ?? []
        shots.wrappedValue = await SteamScreenshots.load(appID: appID, paths: paths)
    }

}

/// One picture of the grid, cut to the design's 4:3 tile.
private struct ShotTile: View {
    let shot: SteamScreenshots.Shot
    let appID: String
    let paths: AppPaths
    @State private var image: NSImage?

    var body: some View {
        Color.chip
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.buttonBorder) }
            .contentShape(.rect)
            .task(id: shot.id) {
                if let file = await SteamScreenshots.thumbnail(shot, appID: appID, paths: paths) {
                    image = NSImage(contentsOf: file)
                }
            }
    }
}

/// A screenshot over the whole window, on black, with the arrow keys or buttons for the others. "Full Screen"
/// takes the window full screen; leaving the viewer gives the window its size back.
struct ScreenshotViewer: View {
    let library: LibraryModel
    @State private var image: NSImage?
    @State private var isFullScreen = false
    @State private var madeFullScreen = false

    var body: some View {
        if let viewing = library.viewing {
            content(viewing)
        }
    }

    private func content(_ viewing: LibraryModel.Viewing) -> some View {
        VStack(spacing: 0) {
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            controls(viewing)
        }
        .padding(.top, isFullScreen ? 0 : 28)
        .background(Color.black.opacity(0.96))
        .environment(\.colorScheme, .dark)
        .onAppear { isFullScreen = window?.styleMask.contains(.fullScreen) ?? false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        .task(id: viewing.index) {
            guard viewing.shots.indices.contains(viewing.index) else { return }
            // The small picture is on disk already: shown at once, then the full one over it.
            let shot = viewing.shots[viewing.index]
            let paths = library.paths
            image = await SteamScreenshots.thumbnail(shot, appID: viewing.appID, paths: paths).flatMap(NSImage.init)
            if let file = await SteamScreenshots.full(shot, appID: viewing.appID, paths: paths) {
                image = NSImage(contentsOf: file)
            }
        }
    }

    private func controls(_ viewing: LibraryModel.Viewing) -> some View {
        HStack(spacing: 8) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(viewing.index == 0)
                .accessibilityLabel("Previous Screenshot")
            Text("\(viewing.index + 1) of \(viewing.shots.count)")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(viewing.index >= viewing.shots.count - 1)
                .accessibilityLabel("Next Screenshot")
            Spacer()
            Button { toggleFullScreen() } label: {
                Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left"
                                               : "arrow.up.left.and.arrow.down.right")
            }
            .keyboardShortcut("f", modifiers: [])
            .accessibilityLabel(isFullScreen ? "Exit Full Screen" : "Full Screen")
            Button("Close") { close() }
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(BrandButtonStyle(height: 30, radius: 8))
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, 4)
    }

    private var window: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    private func toggleFullScreen() {
        madeFullScreen = !isFullScreen
        window?.toggleFullScreen(nil)
    }

    private func close() {
        if madeFullScreen, isFullScreen { window?.toggleFullScreen(nil) }
        library.viewing = nil
    }

    private func step(_ offset: Int) {
        guard var viewing = library.viewing else { return }
        viewing.index = min(max(viewing.index + offset, 0), viewing.shots.count - 1)
        library.viewing = viewing
    }
}
