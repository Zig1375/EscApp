import Foundation

/// One entry of the game database in the manifest: what is known to work for a game, so its first launch starts
/// with that instead of the general rules, and a fix reaches everyone without an app release.
///
/// Values are kept as strings: a backend or Windows version this app doesn't know is ignored instead of making
/// the whole manifest unreadable.
public struct KnownGame: Codable, Sendable, Equatable {
    /// The executable's file name, compared without case.
    public var exe: String
    /// The ProductName from the exe's version info, when the file name alone is too common (`game.exe`).
    public var product: String?
    public var backend: String?
    public var windows: String?
    /// Why, for whoever maintains the list; not shown in the app.
    public var note: String?

    public init(exe: String, product: String? = nil, backend: String? = nil, windows: String? = nil,
                note: String? = nil) {
        self.exe = exe
        self.product = product
        self.backend = backend
        self.windows = windows
        self.note = note
    }

    public var preferredBackend: GraphicsBackend? { backend.flatMap(GraphicsBackend.init(rawValue:)) }
    public var windowsVersion: WindowsVersion? { windows.flatMap(WindowsVersion.init(wineValue:)) }

    public func matches(executable: URL, productName: String?) -> Bool {
        guard executable.lastPathComponent.caseInsensitiveCompare(exe) == .orderedSame else { return false }
        guard let product else { return true }
        return productName?.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(product) == .orderedSame
    }

    /// The first entry that matches.
    public static func find(in games: [KnownGame], executable: URL, productName: String?) -> KnownGame? {
        games.first { $0.matches(executable: executable, productName: productName) }
    }
}
