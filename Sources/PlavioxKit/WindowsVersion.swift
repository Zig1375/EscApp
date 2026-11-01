/// The Windows version a game sees. Changing it rewrites one registry value in the game's bottle
/// (`HKCU\Software\Wine`, value `Version`), so it never needs a new bottle.
public enum WindowsVersion: String, CaseIterable, Codable, Sendable {
    case windowsXP
    case windows7
    case windows10
    case windows11

    public static let `default`: WindowsVersion = .windows10

    /// The value Wine expects in the registry, the same one `winecfg -v` takes.
    public var wineValue: String {
        switch self {
        case .windowsXP: "winxp"
        case .windows7: "win7"
        case .windows10: "win10"
        case .windows11: "win11"
        }
    }

    public init?(wineValue: String) {
        guard let version = Self.allCases.first(where: { $0.wineValue == wineValue.lowercased() }) else { return nil }
        self = version
    }

    public var displayName: String {
        switch self {
        case .windowsXP: "Windows XP"
        case .windows7: "Windows 7"
        case .windows10: "Windows 10"
        case .windows11: "Windows 11"
        }
    }
}
