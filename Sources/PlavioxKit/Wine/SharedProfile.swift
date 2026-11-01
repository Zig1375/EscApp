import Foundation

/// Saves live in one place for every bottle. In the template's Windows user folder, the folders games save to
/// are replaced by links into `Plaviox/Profile`; clones copy the links, so every game bottle, on every runtime,
/// reads and writes the same files.
///
/// `Documents`, `Desktop` and `Downloads` need nothing: Wine already links them to the Mac's own folders.
public enum SharedProfile {
    /// Relative to the Windows user folder (`drive_c/users/<name>`).
    public static let sharedFolders = ["AppData/Roaming", "AppData/Local", "AppData/LocalLow", "Saved Games"]

    /// Replaces each shared folder in `userFolder` with a link into `profile`. Anything Wine already put in a
    /// folder (Start Menu entries, Temp) moves into the profile first, without overwriting what's there.
    public static func link(userFolder: URL, to profile: URL) throws {
        let fileManager = FileManager.default
        for relative in sharedFolders {
            let local = userFolder.appending(path: relative, directoryHint: .isDirectory)
            let shared = profile.appending(path: relative, directoryHint: .isDirectory)
            try fileManager.createDirectory(at: shared, withIntermediateDirectories: true)

            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: local.path) {
                if destination == shared.path { continue }
                try fileManager.removeItem(at: local)
            } else if fileManager.fileExists(atPath: local.path) {
                try merge(local, into: shared)
                try fileManager.removeItem(at: local)
            }
            try fileManager.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(at: local, withDestinationURL: shared)
        }
    }

    /// Moves `source`'s contents into `destination`, keeping whatever `destination` already has.
    private static func merge(_ source: URL, into destination: URL) throws {
        let fileManager = FileManager.default
        for name in try fileManager.contentsOfDirectory(atPath: source.path) {
            let from = source.appending(path: name)
            let into = destination.appending(path: name)
            var isDirectory: ObjCBool = false
            let fromIsFolder = fileManager.fileExists(atPath: from.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
            if !fileManager.fileExists(atPath: into.path) {
                try fileManager.moveItem(at: from, to: into)
            } else if fromIsFolder {
                try merge(from, into: into)
            }
        }
    }
}
