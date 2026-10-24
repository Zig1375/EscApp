import Darwin
import Foundation

/// Looks after the running store clients while EscApp runs: quits one the player closed or whose game is over
/// (`StoreQuit`), and ends the web helper processes Steam left behind (`SteamHelperSweep`).
public actor StoreKeeper {
    /// While nothing is on screen but Wine says a window is shown (minimised, or on another Space), how long
    /// before asking Wine again: each look starts a Windows program.
    static let recheckShown: TimeInterval = 20
    /// A client found running for this long counts as used: it isn't one starting up for a game. Steam left
    /// hidden before EscApp started is quit too.
    static let settledAfter: TimeInterval = 120

    private let client: StoreClient
    private var quits: [Store: StoreQuit] = [:]
    private var shownOffScreen: [Store: Date] = [:]

    public init(paths: AppPaths) { client = StoreClient(paths: paths) }

    /// One look at each of `stores`; returns those whose client runs.
    /// - Parameter busy: stores the app is busy with (installing, one of their games starting or running), which
    ///   count as running a game: Steam is restarted silently for a game first, with no window and no game yet.
    public func check(_ stores: Set<Store>, busy: Set<Store> = []) async -> Set<Store> {
        var running: Set<Store> = []
        for store in stores {
            let bottle = client.bottle(for: store)
            let processes = WineProcesses.running(in: bottle)
            guard !processes.isEmpty, let wine = client.runningWine(store) else {
                quits[store] = nil
                shownOffScreen[store] = nil
                continue
            }
            running.insert(store)
            if store == .steam {
                for pid in SteamHelperSweep.strays(SteamHelperSweep.helpers(in: processes)) { kill(pid, SIGKILL) }
            }
            let game = busy.contains(store) || processes.contains { !store.isClientProgram($0.program) }
            let oldest = processes.compactMap(\.started).min() ?? Date()
            var quit = quits[store] ?? StoreQuit(used: Date().timeIntervalSince(oldest) > Self.settledAfter)
            // A client first seen with nothing on screen may be minimised: ask Wine once.
            let windows = await shown(store, processes: processes, wine: wine,
                                      askWine: quit.watching || quits[store] == nil)
            if quit.update(windows: windows, game: game, now: Date()) {
                quits[store] = nil
                shownOffScreen[store] = nil
                await client.shutDown(store)
                running.remove(store)
            } else {
                quits[store] = quit
            }
        }
        return running
    }

    /// Whether the client shows a window: on screen, as the Mac sees it, or else minimised or on another Space,
    /// as Wine does.
    private func shown(_ store: Store, processes: [WineProcesses.Process], wine: Wine, askWine: Bool) async -> Bool {
        let pids = Set(processes.map(\.pid))
        if GameWindows.owners(under: wine.root).contains(where: pids.contains) {
            shownOffScreen[store] = nil
            return true
        }
        guard askWine else { return false }
        if let asked = shownOffScreen[store], Date().timeIntervalSince(asked) < Self.recheckShown { return true }
        let shown = await StoreWindows.anyShown(in: client.bottle(for: store), wine: wine, host: client.host) ?? true
        shownOffScreen[store] = shown ? Date() : nil
        return shown
    }
}
