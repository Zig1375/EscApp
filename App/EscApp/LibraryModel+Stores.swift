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

    /// "Delete" on a game: one from Steam or Epic asks once and goes to the Trash with the store's record of it
    /// (it can be installed again from the store); one from another store is removed by its client; any other
    /// game asks how (`DeleteGameSheet`).
    func delete(_ game: GameRecord) {
        guard let store = game.store else {
            deleting = game
            return
        }
        if StoreUninstall.canRemove(store) {
            confirmingDelete = game
        } else {
            openStore(store, uninstalling: game.storeID)
        }
    }

    /// The confirmed "Delete" of a Steam or Epic game. A running client keeps its games in memory: Steam went on
    /// showing a deleted game as installed, and writes its records back when it quits. So the client is closed
    /// first and opened again after, and reads that the game is gone.
    func deleteStoreGame(_ game: GameRecord) {
        guard let store = game.store else { return }
        Task {
            let client = StoreClient(paths: paths)
            let wasRunning = client.isRunning(store)
            if wasRunning { await client.shutDown(store) }
            do {
                try StoreUninstall.remove(game, paths: paths)
                reload()
            } catch {
                notice = Notice(title: String(localized: "Couldn't delete \(game.name)"),
                                message: String(describing: error))
            }
            if wasRunning { openStore(store) }
        }
    }

    func games(from store: Store?) -> [GameRecord] {
        games.filter { $0.store == store }
    }
}
