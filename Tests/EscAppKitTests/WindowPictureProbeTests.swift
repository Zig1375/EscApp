import AppKit
@testable import EscAppKit
import Foundation
import Testing

/// Looks at a running program's window the way a first launch does: `ESCAPP_PICTURE_PID=<pid> swift test
/// --filter WindowPictureProbe`. Needs Screen Recording for the terminal.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ESCAPP_PICTURE_PID"] != nil))
struct WindowPictureProbeTests {
    @Test func theWindowOfThatProcess() async throws {
        let pid = try #require(Int32(ProcessInfo.processInfo.environment["ESCAPP_PICTURE_PID"] ?? ""))
        let blank = await WindowPicture.look(windowOf: [pid])
        print("allowed: \(WindowPicture.allowed), blank: \(String(describing: blank))")
        if let path = ProcessInfo.processInfo.environment["ESCAPP_PICTURE_SAVE"],
           let image = await WindowPicture.capture([pid], width: 480) {
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
        }
    }
}
