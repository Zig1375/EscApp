import AppKit
import SwiftUI

/// Settings → General → Language: the app's own language, as macOS keeps it per app. Every one here has a full
/// translation in `Localizable.xcstrings`; `scripts/check-translations.py` keeps it that way.
enum AppLanguage: String, CaseIterable {
    case system
    case english = "en", german = "de", spanish = "es", french = "fr", italian = "it", russian = "ru"
    case japanese = "ja", korean = "ko", chinese = "zh-Hans"

    /// Each language by its own name, as macOS lists them.
    var title: String {
        switch self {
        case .system: String(localized: "As in macOS")
        case .english: "English"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .french: "Français"
        case .italian: "Italiano"
        case .russian: "Русский"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .chinese: "简体中文"
        }
    }
}

extension AppLanguage {
    static var current: Self {
        let chosen = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String]
        guard let first = chosen?.first, UserDefaults.standard.persistentDomain(
            forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] != nil else { return .system }
        return allCases.first { $0 != .system && first.hasPrefix($0.rawValue) } ?? .system
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
