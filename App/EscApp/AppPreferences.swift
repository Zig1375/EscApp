import AppKit
import SwiftUI

/// Settings → General → Language: the app's own language, as macOS keeps it per app.
enum AppLanguage: String, CaseIterable {
    case system, russian = "ru", english = "en"

    var title: String {
        switch self {
        case .system: String(localized: "As in macOS")
        case .russian: "Русский"
        case .english: "English"
        }
    }
}

extension AppLanguage {
    static var current: Self {
        let chosen = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String]
        guard let first = chosen?.first, UserDefaults.standard.persistentDomain(
            forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] != nil else { return .system }
        return first.hasPrefix("ru") ? .russian : first.hasPrefix("en") ? .english : .system
    }

    /// The app's own language, like System Settings → Language & Region → Applications.
    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

/// Settings → General → Appearance: light or dark regardless of macOS, or as macOS has it. Applied to the whole
/// app at once (`NSApp.appearance`), so the game's launch window and the Steam card follow too.
enum AppAppearance: String, CaseIterable {
    case system, light, dark

    static let key = "Appearance"

    var title: String {
        switch self {
        case .system: String(localized: "As in macOS")
        case .light: String(localized: "appearance.light", defaultValue: "Light")
        case .dark: String(localized: "appearance.dark", defaultValue: "Dark")
        }
    }

    /// The one saved in Settings; applied at launch.
    static var saved: Self {
        UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .system
    }

    @MainActor func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
