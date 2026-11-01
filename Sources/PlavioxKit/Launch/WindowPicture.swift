import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Looks at what a game's window shows while a first launch checks it. A Chromium program whose picture never
/// reaches the window stays one flat colour (white for NW.js and Electron, black for others) while everything
/// else about it looks fine: a window, a running process, no error in the log.
///
/// Reading another program's window needs the Screen Recording permission. Without it the answer is "don't
/// know", and the check is skipped; nothing is asked from here (the app asks once, `ScreenAccess`).
/// What one look at a game's window saw.
public struct WindowLook: Sendable, Equatable {
    /// The window's number: a launcher's window and the game's main window are told apart by it.
    public var window: UInt32
    public var blank: Bool
    /// One flat colour but for a small corner: a frozen game keeps whatever its last frame showed. Among Us froze
    /// on black with Steam's overlay notice still in its corner, and counted as drawing.
    public var nearlyBlank: Bool

    public init(window: UInt32, blank: Bool, nearlyBlank: Bool? = nil) {
        self.window = window
        self.blank = blank
        self.nearlyBlank = nearlyBlank ?? blank
    }
}

public enum WindowPicture {
    public static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    /// The largest window of `owners` and whether it is one flat colour; nil when it can't be told, or when the
    /// look takes longer than `timeout` (it must never hold up a launch).
    public static func look(windowOf owners: [Int32]) async -> WindowLook? {
        await withTaskGroup(of: WindowLook??.self) { group in
            group.addTask { await look(at: owners) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .some(nil)
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    static let timeout: Duration = .seconds(3)

    private static func look(at owners: [Int32]) async -> WindowLook? {
        guard let window = largestWindow(of: owners), let image = await capture(window) else { return nil }
        let share = flatShare(image)
        return WindowLook(window: window, blank: share >= 1, nearlyBlank: share >= nearlyBlankShare)
    }

    /// A small picture of the largest window of `owners`.
    static func capture(_ owners: [Int32], width: Int = 96) async -> CGImage? {
        guard let window = largestWindow(of: owners) else { return nil }
        return await capture(window, width: width)
    }

    static func capture(_ target: CGWindowID, width: Int = 96) async -> CGImage? {
        guard allowed else { return nil }
        // ScreenCaptureKit needs the process connected to the window server, which an app is and the CLI isn't:
        // without it the capture aborts the process.
        await MainActor.run { _ = NSApplication.shared }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return nil }
        // The window by its number, as the rest of Plaviox sees the game's windows: ScreenCaptureKit's own list
        // gave an Electron program's real window to no process, and its hidden 500×500 one to the game.
        guard let window = content.windows.first(where: { $0.windowID == target }) else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = max(Int(Double(width) * window.frame.height / max(window.frame.width, 1)), 48)
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// The number of the largest on-screen window of `owners` at a game's window level (`GameWindows`).
    static func largestWindow(of owners: [Int32]) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        let candidates = windows.compactMap { window -> (CGWindowID, CGFloat)? in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, owners.contains(pid),
                  let layer = window[kCGWindowLayer as String] as? Int, GameWindows.isGameLayer(layer),
                  let number = window[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 120, frame.height >= 90 else { return nil }
            return (number, frame.width * frame.height)
        }
        return candidates.max { $0.1 < $1.1 }?.0
    }

    /// The share of the picture that must be flat for `WindowLook.nearlyBlank`. Steam's overlay notice took 0.5%.
    static let nearlyBlankShare = 0.97

    /// How much of the picture is the colour of its top-left corner, from 0 to 1.
    static func flatShare(_ image: CGImage) -> Double {
        let width = 48, height = 36
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return flatShare(pixels: pixels, width: width, height: height)
    }

    /// One flat colour, leaving out a title bar and the frame: every pixel within a few steps of the first.
    static func isBlank(pixels: [UInt8], width: Int, height: Int) -> Bool {
        flatShare(pixels: pixels, width: width, height: height) >= 1
    }

    /// RGBA rows, top first. The top fifth (a title bar) and a two-pixel frame are left out.
    static func flatShare(pixels: [UInt8], width: Int, height: Int) -> Double {
        let first = ((height / 5) * width + 2) * 4
        var same = 0, total = 0
        for y in (height / 5)..<(height - 2) {
            for x in 2..<(width - 2) {
                let index = (y * width + x) * 4
                total += 1
                if (0..<3).allSatisfy({ abs(Int(pixels[index + $0]) - Int(pixels[first + $0])) <= 10 }) { same += 1 }
            }
        }
        return total == 0 ? 0 : Double(same) / Double(total)
    }
}
