import AppKit
import Foundation
import UniformTypeIdentifiers

/// Opening .exe and .msi files from Finder.
extension LibraryModel {
    /// The types Finder opens .exe and .msi files as, by extension: where Whisky declared it, an .msi is
    /// `com.microsoft.msi-installer` rather than the `com.microsoft.windows-installer` Magic Kettle declares.
    private static var exeTypes: [UTType] { ["exe", "msi"].compactMap { UTType(filenameExtension: $0) } }

    /// The first screen says to double-click a game's .exe, but on a Mac that had Whisky (or an earlier build under
    /// another bundle id) Finder kept opening .exe files with that app. So the first launch takes them without asking;
    /// an app the player picks in Finder later keeps them.
    func claimExeFilesOnce() {
        let key = "ClaimedExeFiles"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        makeDefaultForExe()
    }

    func makeDefaultForExe() {
        Task {
            // Launch Services picks among copies with this bundle id, and kept picking a day-old development
            // build in DerivedData: double-clicking an .exe opened that copy, with its old first-launch screen.
            // Registering this copy first makes it the one chosen.
            LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
            // Not `NSWorkspace.setDefaultApplication`, which asks the player to confirm in a system alert.
            if let bundleID = Bundle.main.bundleIdentifier {
                for type in Self.exeTypes {
                    LSSetDefaultRoleHandlerForContentType(type.identifier as CFString, .all, bundleID as CFString)
                }
            }
            // Launch Services takes a moment to answer with the new handler.
            for _ in 0..<10 where !isDefaultForExe {
                refreshDefaultHandler()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// By bundle id, not path: with two copies of Magic Kettle on the Mac (a development build in DerivedData and one
    /// elsewhere) Launch Services may name the other copy, and the switch in Settings stayed off after it was
    /// approved. `makeDefaultForExe` registers this copy first so that it is the one that opens.
    func refreshDefaultHandler() {
        guard let type = UTType(filenameExtension: "exe"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: type) else {
            isDefaultForExe = false
            return
        }
        isDefaultForExe = Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}
