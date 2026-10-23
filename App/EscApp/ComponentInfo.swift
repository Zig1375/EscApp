import EscAppKit
import Foundation

/// How components are named and explained to people. Kept in one place so setup and settings say the same.
extension RuntimeManifest.Component.Kind {
    var title: String {
        switch self {
        case .wine: "Wine"
        case .mono: "Wine Mono"
        case .dxvk: "DXVK"
        case .dxmt: "DXMT"
        }
    }

    var role: String {
        switch self {
        case .wine: String(localized: "Runs Windows programs")
        case .mono: String(localized: ".NET for games and installers that need it")
        case .dxvk, .dxmt: String(localized: "Graphics for DirectX 10 and 11 games")
        }
    }
}

extension Version {
    static var thisApp: Version {
        Version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") ?? .zero
    }

    static var thisMac: Version {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return Version("\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)") ?? .zero
    }
}
