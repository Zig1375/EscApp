import Foundation

/// Settings that apply to every game, in `Settings.json` rather than the app's defaults so `escapp run` launches
/// a game the same way the app does.
public struct SharedSettings: Codable, Sendable, Equatable {
    /// Settings → General: no game gets Retina, whatever its own setting says. For a player who wants every game
    /// at the size its interface was made for, without changing each one in its Advanced settings.
    public var retinaOff: Bool?

    public init(retinaOff: Bool? = nil) {
        self.retinaOff = retinaOff
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
