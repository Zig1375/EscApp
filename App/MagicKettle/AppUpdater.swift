import Foundation
import Sparkle

/// Updates Magic Kettle itself through Sparkle; the components games run on are updated by `ComponentsModel`.
/// A player pressed "Check for Updates" in Settings and nothing happened: it only looked at Wine, DXVK and DXMT,
/// and a new release of the app reached nobody. The release job in ci.yml signs the zip with the EdDSA key whose
/// public half is `SUPublicEDKey` and attaches `appcast.xml` to the release, so `SUFeedURL` always names the newest.
@MainActor
final class AppUpdater {
    private let controller: SPUStandardUpdaterController?

    init() {
        // A local build is build 0 (project.yml): Sparkle would offer to replace it with the published release.
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        controller = (Int(build ?? "") ?? 0) > 0
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    /// Sparkle shows its own window: the new version and its notes, or that this one is the newest.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
