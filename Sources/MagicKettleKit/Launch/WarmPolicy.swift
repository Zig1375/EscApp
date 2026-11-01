import Foundation

/// When Magic Kettle warms bottles (`BottleWarmer`), as plain rules the app follows: only while Magic Kettle is in
/// front and no game runs, for the last played game and a game the player is looking at, and never on Macs with less
/// than 16 GB.
public enum WarmPolicy {
    /// After Magic Kettle loses focus, its warm bottles go this much later: switching away for a moment keeps them.
    public static let coolAfterFocusLoss: Duration = .seconds(5)
    /// How long the pointer rests on a card before its game warms, so a pass across the library doesn't start
    /// Wine for every game it crosses.
    public static let hoverDelay: Duration = .milliseconds(400)

    /// - Parameter gamesRunning: any game starting or running; it needs the memory, and its own bottle is
    ///   already warm.
    public static func mayWarm(ready: Bool, appActive: Bool, gamesRunning: Bool,
                               memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        ready && appActive && !gamesRunning && memory >= BottleWarmer.minimumMemory
    }

    /// The game warmed when Magic Kettle comes to the front: the one played last. A game never played has no bottle.
    /// Store and disc games are never warmed (`WineWarmUp.canWarm`), so they don't count: after a game from Steam,
    /// nothing was warmed at all and every game started cold.
    public static func lastPlayed(_ games: [GameRecord]) -> GameRecord? {
        games.filter { $0.store == nil && $0.disc == nil }
            .compactMap { game in game.lastPlayed.map { (game, $0) } }.max { $0.1 < $1.1 }?.0
    }
}
