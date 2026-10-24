import Foundation

/// Puts EscApp's wrapper (`tools/chromium-helper`) in front of a store client's Chromium helper, so its window
/// draws. Without it Steam's sign-in window stays black: Chromium's separate GPU process draws into a window
/// another process owns, which Wine's Mac driver can't show. The wrapper restarts the real helper, renamed
/// `<name>_real.exe`, with that work moved into the helper itself.
///
/// It only ever replaces the vendor's helper with the wrapper and keeps the vendor's file as `_real.exe`. A
/// client update puts its new helper back in place; the next start wraps it again.
public enum ChromiumHelper {
    /// Written into the wrapper; tells it from the vendor's helper.
    static let marker = Data("escapp-chromium-helper/1".utf8)

    static var wrapper: Data? {
        Bundle.module.url(forResource: "chromium-helper", withExtension: "exe").flatMap { try? Data(contentsOf: $0) }
    }

    /// Wraps each helper `store` has in `bottle`. Only while the client isn't running: Windows can't replace a
    /// running program's file, and Wine keeps it open the same way.
    @discardableResult
    public static func wrap(_ store: Store, in bottle: URL) throws -> [URL] {
        guard let wrapper else { return [] }
        let drive = bottle.appending(path: "drive_c", directoryHint: .isDirectory)
        var wrapped: [URL] = []
        for pattern in store.chromiumHelpers {
            for helper in expand(pattern, in: drive) where try wrap(helper, with: wrapper) {
                wrapped.append(helper)
            }
        }
        return wrapped
    }

    /// Whether a helper in `bottle` is the vendor's own file: the client put it back (its self-update, or an
    /// install EscApp didn't see to the end), so it runs unwrapped and its window is black.
    public static func needsWrapping(_ store: Store, in bottle: URL) -> Bool {
        guard wrapper != nil else { return false }
        let drive = bottle.appending(path: "drive_c", directoryHint: .isDirectory)
        return store.chromiumHelpers.flatMap { expand($0, in: drive) }.contains { helper in
            (try? Data(contentsOf: helper, options: .alwaysMapped))?.range(of: marker) == nil
        }
    }

    /// The helpers a pattern names; a `*` part matches each folder at that place.
    static func expand(_ pattern: String, in root: URL) -> [URL] {
        var found = [root]
        for part in pattern.split(separator: "/").map(String.init) {
            found = found.flatMap { folder -> [URL] in
                guard part == "*" else { return [folder.appending(path: part)] }
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                return names.filter { !$0.hasPrefix(".") }
                    .map { folder.appending(path: $0, directoryHint: .isDirectory) }
            }
        }
        return found.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Returns whether it changed anything.
    static func wrap(_ helper: URL, with wrapper: Data) throws -> Bool {
        let fileManager = FileManager.default
        let real = helper.deletingLastPathComponent()
            .appending(path: helper.deletingPathExtension().lastPathComponent + "_real.exe")
        let current = try Data(contentsOf: helper, options: .alwaysMapped)
        if current.range(of: marker) != nil {
            // Already wrapped; a newer wrapper replaces an older one. Without the real helper next to it the
            // wrapper can't start anything, which the client's own file check repairs.
            guard current != wrapper, fileManager.fileExists(atPath: real.path) else { return false }
            try wrapper.write(to: helper, options: .atomic)
            return true
        }
        // The vendor's helper, new or updated: it becomes the real one, the old copy goes.
        try? fileManager.removeItem(at: real)
        try fileManager.moveItem(at: helper, to: real)
        do {
            try wrapper.write(to: helper, options: .atomic)
        } catch {
            try? fileManager.moveItem(at: real, to: helper)
            throw error
        }
        return true
    }
}
