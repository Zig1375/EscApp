import Foundation

/// Looks after the running store clients while EscApp runs: quits one the player closed or whose game is over
/// (`StoreQuit`), and lets each store tidy up after its client (`StoreModule.tidy`: the web helper processes
/// Steam left behind).
public actor StoreKeeper {
    /// While nothing is on screen but Wine says a window is shown (minimised, or on another Space), how long
    /// before asking Wine again: each look starts a Windows program.
    static let recheckShown: TimeInterval = 20
    /// The same while only minimised windows were seen, for a while after the window left the screen: Epic
    /// minimises its window when the player closes it and hides it a moment later. Asked in that moment, a 20 s
    /// wait kept the closed launcher running half a minute.
    static let recheckMinimised: TimeInterval = 3
    static let closingFor: TimeInterval = 30
    /// A client found running for this long counts as used: it isn't one starting up for a game. Steam left
    /// hidden before EscApp started is quit too.
    static let settledAfter: TimeInterval = 120

    private let client: StoreClient
    private var quits: [Store: StoreQuit] = [:]
    /// When the oldest process in each store's bottle started: a later one is the client started again.
    private var sessions: [Store: Date] = [:]
    /// When Wine last said a window is shown though none is on screen, and whether all of them were minimised.
    private var shownOffScreen: [Store: (asked: Date, minimised: Bool)] = [:]
    /// When the client's windows left the screen.
    private var offScreenSince: [Store: Date] = [:]

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
                offScreenSince[store] = nil
                sessions[store] = nil
                continue
            }
            running.insert(store)
            store.module.tidy(processes)
            let game = busy.contains(store) || Self.playing(store, in: bottle, processes: processes)
            let started = processes.compactMap(\.started).min()
            if Self.restarted(seen: sessions[store], oldest: started) {
                quits[store] = nil
                shownOffScreen[store] = nil
                offScreenSince[store] = nil
            }
            sessions[store] = started ?? sessions[store]
            let oldest = started ?? Date()
            var quit = quits[store] ?? StoreQuit(used: Date().timeIntervalSince(oldest) > Self.settledAfter)
            // A client first seen with nothing on screen may be minimised: ask Wine once.
            let windows = await shown(store, processes: processes, wine: wine,
                                      askWine: quit.watching || quits[store] == nil)
            if quit.update(windows: windows, game: game, now: Date()) {
                quits[store] = nil
                shownOffScreen[store] = nil
                offScreenSince[store] = nil
                // Checked again just before Wine is ended: a game may start while the client is asked to quit.
                await client.shutDown(store) { Self.playing(store, in: bottle) }
                running.remove(store)
            } else {
                quits[store] = quit
            }
        }
        return running
    }

    /// Whether everything in the bottle started again since the last look: Epic's launcher restarted by
    /// `watchEpicUpdates`, or closed and opened between two looks. That is a new client, not yet used: kept as
    /// the old one, it was seen without a window while starting up and quit 8 s later, before its window opened.
    static func restarted(seen: Date?, oldest: Date?) -> Bool {
        guard let seen, let oldest else { return false }
        return oldest.timeIntervalSince(seen) > 1
    }

    /// A game of the store's running, or the client busy with something quitting would break (Steam getting a
    /// game ready, or downloading).
    static func playing(_ store: Store, in bottle: URL, processes: [WineProcesses.Process]? = nil) -> Bool {
        (processes ?? WineProcesses.running(in: bottle)).contains { !store.isClientProgram($0.program) }
            || store.module.isBusy(bottle: bottle)
    }

    /// Whether the client shows a window: on screen, as the Mac sees it, or else minimised or on another Space,
    /// as Wine does.
    private func shown(_ store: Store, processes: [WineProcesses.Process], wine: Wine, askWine: Bool) async -> Bool {
        let pids = Set(processes.map(\.pid))
        let now = Date()
        if GameWindows.owners(under: wine.root).contains(where: pids.contains) {
            shownOffScreen[store] = nil
            offScreenSince[store] = nil
            return true
        }
        let offScreen = offScreenSince[store] ?? now
        offScreenSince[store] = offScreen
        guard askWine else { return false }
        if let last = shownOffScreen[store],
           !Self.askAgain(asked: last.asked, minimised: last.minimised, offScreenSince: offScreen, now: now) {
            return true
        }
        let shown = await StoreWindows.shown(in: client.bottle(for: store), wine: wine, host: client.host) ?? .windows
        shownOffScreen[store] = shown == .nothing ? nil : (now, shown == .minimised)
        return shown != .nothing
    }

    /// Whether to ask Wine again about windows it said are shown while none is on screen: each look starts a
    /// Windows program, so a minimised client is asked rarely, but a client that only just left the screen with
    /// nothing but minimised windows may be closing.
    static func askAgain(asked: Date, minimised: Bool, offScreenSince: Date, now: Date) -> Bool {
        let closing = minimised && now.timeIntervalSince(offScreenSince) < closingFor
        return now.timeIntervalSince(asked) >= (closing ? recheckMinimised : recheckShown)
    }
}
