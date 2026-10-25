import Foundation

/// Settings for all games, in `Settings.json` rather than the app's defaults so a game `escapp` adds gets them
/// just like one the app adds.
public struct SharedSettings: Codable, Sendable, Equatable {
    /// Settings → General: the Retina setting a game gets when it is added; nil is Auto. Only the default: each
    /// game keeps its own choice afterwards, since games that draw for Retina look better with it while others
    /// need it off (clicks missed the buttons of one that didn't handle it).
    public var newGameRetina: GameScaling.Setting?

    public init(newGameRetina: GameScaling.Setting? = nil) {
        self.newGameRetina = newGameRetina
    }

    /// The default as a game's own setting, which stores Auto as nil.
    public static func newGameRetina(paths: AppPaths) -> GameScaling.Setting? {
        let setting = load(from: paths.settings).newGameRetina
        return setting == .auto ? nil : setting
    }

    /// The saved settings; the defaults when there are none or the file can't be read.
    public static func load(from file: URL) -> SharedSettings {
        guard let data = try? Data(contentsOf: file) else { return SharedSettings() }
        return (try? JSONDecoder().decode(SharedSettings.self, from: data)) ?? SharedSettings()
    }

    public func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
    }
}
