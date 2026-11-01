import Foundation
import Observation
import PlavioxKit

/// Gets this Mac ready to run games: Rosetta, then the runtime from the bundled manifest.
/// The setup screen only draws this state.
@MainActor @Observable
final class RuntimeSetup {
    enum Phase: Equatable {
        case checking
        /// Rosetta is missing; installing it means accepting Apple's license, which only the user can do.
        case needsRosettaConsent
        case working
        case ready
        case failed(String)
    }

    enum ItemState: Equatable {
        case waiting
        case active(fraction: Double?)
        case done
        case failed
    }

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        var state: ItemState = .waiting
    }

    private(set) var phase: Phase = .checking
    private(set) var items: [Item] = []

    private let paths: AppPaths
    private var runtime: RuntimeManifest.Runtime?

    init(paths: AppPaths = .standard()) {
        self.paths = paths
        // Decide before the first frame: checking is just reading a few small files, and doing it later
        // flashed the setup screen on every launch even when everything was installed.
        RuntimeInstaller(paths: paths).removeLeftovers()
        check()
    }

    func check() {
        let manifest: RuntimeManifest
        do {
            // The cached list from the last update check if there is one, otherwise the copy inside the app.
            manifest = try ManifestUpdater(paths: paths).current()
        } catch {
            phase = .failed(String(describing: error))
            return
        }
        guard let runtime = manifest.newest(forApp: .thisApp, macOS: .thisMac) else {
            phase = .failed(String(localized: "This Mac needs a newer version of Plaviox."))
            return
        }
        self.runtime = runtime
        items = [Item(id: "rosetta", title: "Rosetta 2", detail: String(localized: "Apple's translator for Intel apps"),
                      state: Rosetta.isInstalled() ? .done : .waiting)]
            + runtime.components.map { component in
                Item(id: component.kind.rawValue, title: component.kind.title,
                     detail: Self.detail(component))
            }
        // Any installed runtime is enough to play. A newer one in the list is an update the user is offered
        // in Settings and the library banner, never a reason to block them with this screen again.
        let catalog = RuntimeCatalog(installed: RuntimeInstaller(paths: paths).installedRuntimes(),
                                     manifest: manifest, app: .thisApp, macOS: .thisMac)
        if Rosetta.isInstalled(), !catalog.installed.isEmpty {
            items = items.map { var item = $0; item.state = .done; return item }
            phase = .ready
        } else if !Rosetta.isInstalled() {
            phase = .needsRosettaConsent
        } else {
            Task { await install() }
        }
    }

    /// The user agreed to Apple's license in the setup screen.
    func acceptRosettaLicense() {
        Task {
            phase = .working
            update("rosetta", .active(fraction: nil))
            do {
                try await Rosetta.installAcceptingLicense()
                update("rosetta", .done)
                await install()
            } catch {
                update("rosetta", .failed)
                phase = .failed(String(localized: "Rosetta couldn't be installed: \(String(describing: error))"))
            }
        }
    }

    func retry() {
        phase = .checking
        check()
    }

    private func install() async {
        guard let runtime else { return }
        phase = .working
        let throttle = ProgressThrottle()
        do {
            try await RuntimeInstaller(paths: paths).install(runtime) { step in
                guard let (id, state) = throttle.filter(step) else { return }
                Task { @MainActor in self.apply(id, state) }
            }
            items = items.map { var item = $0; item.state = .done; return item }
            phase = .ready
        } catch {
            if let active = items.first(where: { if case .active = $0.state { true } else { false } }) {
                update(active.id, .failed)
            }
            phase = .failed(String(describing: error))
        }
    }

    private func apply(_ id: String, _ state: ItemState) {
        // Starting one component means every earlier one is finished.
        if let index = items.firstIndex(where: { $0.id == id }) {
            for earlier in items.indices where earlier < index && items[earlier].state != .done {
                items[earlier].state = .done
            }
        }
        update(id, state)
    }

    private func update(_ id: String, _ state: ItemState) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
    }

    private static func detail(_ component: RuntimeManifest.Component) -> String {
        let size = ByteCountFormatter.string(fromByteCount: component.size, countStyle: .file)
        return "\(component.kind.role) · \(component.version) · \(size)"
    }
}

/// Download progress arrives for every network chunk; the screen only needs a change of about half a percent.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: (id: String, permille: Int)?

    func filter(_ step: RuntimeInstaller.Step) -> (String, RuntimeSetup.ItemState)? {
        let id: String, permille: Int, state: RuntimeSetup.ItemState
        switch step {
        case let .downloading(kind, received, total):
            id = kind.rawValue
            permille = total > 0 ? Int(received * 1000 / total) : 0
            state = .active(fraction: Double(permille) / 1000)
        case let .unpacking(kind):
            id = kind.rawValue
            permille = 1001
            state = .active(fraction: nil)
        case .finishing:
            return nil
        }
        return lock.withLock {
            if let last, last.id == id, abs(last.permille - permille) < 5, permille <= 1000 { return nil }
            last = (id, permille)
            return (id, state)
        }
    }
}
