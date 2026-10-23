import ExePortKit
import Foundation
import Observation

/// What's installed, whether the component list has something newer, and installing that update.
@MainActor @Observable
final class ComponentsModel {
    struct UpdateProgress: Equatable {
        var label: String
        var fraction: Double?
    }

    private(set) var catalog: RuntimeCatalog?
    private(set) var sizes: [String: Int64] = [:]
    private(set) var rosettaInstalled = Rosetta.isInstalled()
    private(set) var lastChecked: Date?
    private(set) var isChecking = false
    private(set) var checkError: String?
    private(set) var updating: UpdateProgress?
    private(set) var updateError: String?

    var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: Self.autoCheckKey) }
    }

    private static let autoCheckKey = "AutoCheckComponentUpdates"
    private let paths: AppPaths
    private var updater: ManifestUpdater { ManifestUpdater(paths: paths) }
    private var installer: RuntimeInstaller { RuntimeInstaller(paths: paths) }

    init(paths: AppPaths = .standard()) {
        self.paths = paths
        autoCheck = UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true
    }

    /// Re-reads the disk and the cached list. Cheap; no network.
    func reload() {
        rosettaInstalled = Rosetta.isInstalled()
        lastChecked = updater.cached()?.checkedAt
        guard let manifest = try? updater.current() else { return }
        let installed = installer.installedRuntimes()
        catalog = RuntimeCatalog(installed: installed, manifest: manifest, app: .thisApp, macOS: .thisMac)
        let installer = installer
        Task.detached(priority: .utility) {
            let sizes = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, installer.diskSize(of: $0)) })
            await MainActor.run { self.sizes = sizes }
        }
    }

    func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        checkError = nil
        defer { isChecking = false }
        do {
            try await updater.check()
        } catch {
            checkError = String(localized: "Couldn't check for updates. ExePort will try again later.")
        }
        reload()
    }

    /// Called on launch and every hour; checks at most once a day, and never if the user turned it off.
    func checkIfDue() async {
        guard autoCheck, ManifestUpdater.isDue(lastChecked: updater.cached()?.checkedAt) else { return }
        await checkNow()
    }

    /// Installs the newest runtime next to the current one. The old one stays until no game needs it.
    func installUpdate() async {
        guard case let .updateAvailable(_, newest)? = catalog?.status, updating == nil else { return }
        updating = UpdateProgress(label: String(localized: "Preparing…"))
        updateError = nil
        do {
            try await installer.install(newest) { step in
                let progress: UpdateProgress? = switch step {
                case let .downloading(kind, received, total):
                    UpdateProgress(label: String(localized: "Downloading \(kind.title)…"),
                                   fraction: total > 0 ? Double(received) / Double(total) : nil)
                case let .unpacking(kind):
                    UpdateProgress(label: String(localized: "Installing \(kind.title)…"))
                case .finishing:
                    UpdateProgress(label: String(localized: "Finishing…"))
                }
                Task { @MainActor in
                    // Chunks arrive constantly; only redraw when the bar moves visibly.
                    if self.updating?.label != progress?.label
                        || abs((self.updating?.fraction ?? 0) - (progress?.fraction ?? 0)) > 0.005 {
                        self.updating = progress
                    }
                }
            }
        } catch {
            updateError = String(describing: error)
        }
        updating = nil
        reload()
    }
}
