import Foundation
import Observation
import PlavioxKit

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
    private(set) var diskUsage: DiskUsage?

    /// "Update components automatically" in Settings: check daily and install what's new without asking.
    var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: Self.autoCheckKey) }
    }

    private static let autoCheckKey = "AutoCheckComponentUpdates"
    let paths: AppPaths
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
            checkError = String(localized: "Couldn't check for updates. Plaviox will try again later.")
        }
        reload()
    }

    /// The daily check: a failure stays quiet (no network, GitHub down) and the next one simply tries again.
    /// Only "Check for Updates" reports it.
    private func checkQuietly() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        try? await updater.check()
        reload()
    }

    /// Called on launch and every hour; checks at most once a day, and never if the user turned it off.
    func checkIfDue() async {
        guard autoCheck else { return }
        // The settings Plaviox knows for particular games, fetched whole and quietly; the next launch uses them.
        let modules = GameModulesUpdater(paths: paths)
        if GameModulesUpdater.isDue(lastChecked: modules.cached()?.checkedAt) { _ = try? await modules.check() }
        guard ManifestUpdater.isDue(lastChecked: updater.cached()?.checkedAt) else { return }
        await checkQuietly()
        // The new runtime replaces the current one; games move to it at their next launch.
        if catalog?.updateAvailable == true { await installUpdate() }
    }

    /// Recounts what Plaviox takes on disk (a few seconds on a large library, so off the main thread).
    func measureDisk() {
        let paths = paths
        Task.detached(priority: .utility) {
            let usage = DiskUsage.measure(paths: paths)
            await MainActor.run { self.diskUsage = usage }
        }
    }

    /// Installs the newest runtime and removes the old one: games move to the new one at their next launch.
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
            removeOldRuntimes(keeping: newest.id)
        } catch {
            updateError = String(describing: error)
        }
        updating = nil
        reload()
    }

    /// Deletes runtimes older than `current`, also on launch for an update that found something still running
    /// from the old one. Off the main thread: a runtime is about a gigabyte of small files.
    func removeOldRuntimes(keeping current: String? = nil) {
        guard let current = current ?? catalog?.current?.id else { return }
        let installer = installer
        Task.detached(priority: .utility) {
            guard !installer.removeOlder(keeping: current).isEmpty else { return }
            await MainActor.run { self.reload() }
        }
    }
}
