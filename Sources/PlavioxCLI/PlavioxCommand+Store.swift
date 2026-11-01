import Foundation
import PlavioxKit

extension PlavioxCommand {
    /// `plaviox store …`: the Stores screen from the command line.
    func store(_ arguments: [String]) async -> Output {
        switch arguments.first {
        case "list"?:
            return success(storeList())
        case "sync"?:
            do {
                try StoreLibrary.sync(paths: paths)
                return success(storeGames())
            } catch {
                return failure("\(error)")
            }
        case let action?:
            guard arguments.count == 2, let store = Store(rawValue: arguments[1]) else {
                let names = Store.allCases.map(\.rawValue).joined(separator: ", ")
                return failure("store \(action) needs one of: \(names)")
            }
            do {
                return try await storeAction(action, store)
            } catch {
                return failure("\(error)")
            }
        case nil:
            return failure("store needs list, install, open, close, remove or sync")
        }
    }

    private func storeAction(_ action: String, _ store: Store) async throws -> Output {
        let client = StoreClient(paths: paths, host: host)
        switch action {
        case "install":
            guard let runtime = try manifest().newest(forApp: Self.appVersion, macOS: Self.macOSVersion) else {
                return failure("No runtime suits this Mac.")
            }
            try await client.install(store, runtime: runtime, progress: report(store))
            try StoreLibrary.sync(paths: paths)
            return success("\(store.name) is installed in \(client.bottle(for: store).path(percentEncoded: false))")
        case "open":
            guard let runtime = try manifest().newest(forApp: Self.appVersion, macOS: Self.macOSVersion) else {
                return failure("No runtime suits this Mac.")
            }
            try await client.open(store, runtime: runtime)
            return success("\(store.name) is starting")
        case "close":
            await client.shutDown(store)
            return success("\(store.name) is closed")
        case "remove":
            try await client.uninstall(store)
            return success("\(store.name) and its games are removed")
        default:
            return failure("Unknown store action: \(action)")
        }
    }

    /// One line per ten percent of each download.
    private func report(_ store: Store) -> @Sendable (StoreClient.Step) -> Void {
        let progress = progress
        let last = LastPercent()
        return { step in
            switch step {
            case let .downloading(received, total?):
                let percent = Int(received * 100 / max(total, 1))
                if last.changed(to: percent / 10) { progress("Downloading \(percent)%") }
            case let .updating(received?, total?):
                let percent = Int(received * 100 / max(total, 1))
                if last.changed(to: 100 + percent / 10) { progress("Client \(percent)%") }
            case .downloading: break
            case .installing: progress("Running \(store.name)'s installer")
            case .updating: progress("\(store.name) is downloading its client")
            }
        }
    }

    private func storeList() -> String {
        let client = StoreClient(paths: paths, host: host)
        return Store.allCases.map { store in
            let state = !client.isInstalled(store) ? "not installed" : client.isRunning(store) ? "running" : "installed"
            return "\(store.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(store.name): \(state)"
        }.joined(separator: "\n")
    }

    private func storeGames() -> String {
        let games = ((try? GameLibrary.load(from: paths.library))?.games ?? []).filter { $0.store != nil }
        guard !games.isEmpty else { return "No store games installed." }
        return games.map { "\($0.store?.name ?? "") \($0.storeID ?? ""): \($0.name) — \($0.executable)" }
            .joined(separator: "\n")
    }
}

/// Remembers the last tenth printed.
private final class LastPercent: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1

    func changed(to new: Int) -> Bool {
        lock.withLock {
            defer { value = new }
            return new != value
        }
    }
}
