import AppKit
import EscAppKit
import Foundation

/// The Stores screen (Stores.dc.html): installing a store's client, opening it, removing it, and the store's
/// games showing in the library by themselves.
extension LibraryModel {
    enum StoreState: Equatable {
        case notInstalled
        case installing(StoreClient.Step)
        case installed
    }

    func state(of store: Store) -> StoreState {
        if let step = storeInstalls[store] { return .installing(step) }
        return installedStores.contains(store) ? .installed : .notInstalled
    }

    /// Reads which clients are installed and brings the stores' games into the library. Cheap: a few small files
    /// per store.
    func refreshStores() {
        let client = StoreClient(paths: paths)
        installedStores = Set(Store.allCases.filter(client.isInstalled))
        let paths = paths
        Task.detached(priority: .utility) {
            let changed = (try? StoreLibrary.sync(paths: paths)) ?? false
            if changed { await MainActor.run { self.reload() } }
        }
    }

    /// While EscApp runs, a store may install or remove games at any time: look every 15 seconds.
    func watchStores() {
        Task {
            while !Task.isCancelled {
                refreshStores()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func installStore(_ store: Store) {
        guard storeInstalls[store] == nil else { return }
        storeInstalls[store] = .downloading(received: 0, total: nil)
        storeTasks[store] = Task {
            defer {
                storeInstalls[store] = nil
                storeTasks[store] = nil
                refreshStores()
            }
            do {
                guard let (runtime, _) = try currentRuntime() else { throw BottleError.runtimeMissing("") }
                try await StoreClient(paths: paths).install(store, runtime: runtime) { step in
                    Task { @MainActor in
                        if self.storeInstalls[store] != nil { self.storeInstalls[store] = step }
                    }
                }
            } catch is CancellationError {
                // "Cancel": the half-made bottle goes.
                try? await StoreClient(paths: paths).uninstall(store)
            } catch {
                notice = Notice(title: String(localized: "Couldn't install \(store.name)"),
                                message: String(describing: error))
            }
        }
    }

    func cancelStoreInstall(_ store: Store) {
        storeTasks[store]?.cancel()
    }

    func openStore(_ store: Store, uninstalling storeID: String? = nil) {
        Task {
            do {
                guard let (runtime, _) = try currentRuntime() else { throw BottleError.runtimeMissing("") }
                try await StoreClient(paths: paths).open(store, runtime: runtime, uninstalling: storeID)
            } catch {
                notice = Notice(title: String(localized: "Couldn't open \(store.name)"),
                                message: String(describing: error))
            }
        }
    }

    /// "Remove…", once confirmed.
    func removeStore(_ store: Store) {
        Task {
            do {
                try await StoreClient(paths: paths).uninstall(store)
            } catch {
                notice = Notice(title: String(localized: "Couldn't remove \(store.name)"),
                                message: String(describing: error))
            }
            refreshStores()
            reload()
        }
    }

    /// A store game's "Delete…": the store removes its own games, so its client opens to do it. The game leaves
    /// EscApp once the store has removed it.
    func uninstallInStore(_ game: GameRecord) {
        guard let store = game.store else { return }
        openStore(store, uninstalling: game.storeID)
    }

    func games(from store: Store?) -> [GameRecord] {
        games.filter { $0.store == store }
    }
}
