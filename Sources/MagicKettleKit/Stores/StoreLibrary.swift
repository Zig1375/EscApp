import Foundation

/// The games each store has installed in its bottle, read from the store's own records, and kept in `Games.json`
/// so they show in the library like any other game ("Steam games appear in Magic Kettle by themselves").
///
/// Each store records its games its own way (`StoreModule.games`): Steam in `appmanifest_<id>.acf` files in each
/// library folder, Epic in a JSON `.item` per game. Reading them is pure file parsing, tested without Wine.
public enum StoreLibrary {
    /// One installed game, as its store records it.
    public struct Game: Sendable, Equatable {
        public var store: Store
        public var id: String
        public var name: String
        public var folder: URL
        /// The program the store says starts the game, when it says so (Epic). Otherwise Magic Kettle picks one
        /// from the folder, for the icon and to tell which DirectX the game uses.
        public var executable: URL?
    }

    public static func games(of store: Store, bottle: URL) -> [Game] { store.module.games(bottle: bottle) }
}

extension StoreLibrary {
    /// Brings `Games.json` in line with what the stores have installed: new games are added, games a store
    /// uninstalled go, and a game keeps its id, play time and settings while it stays. Games from a store whose
    /// client was removed go too. Returns whether anything changed.
    @discardableResult
    public static func sync(paths: AppPaths, now: Date = Date()) throws -> Bool {
        var found: [Store: [Game]] = [:]
        for store in Store.allCases {
            let bottle = paths.bottle(forGame: store.bottleID)
            found[store] = store.client(in: bottle) == nil ? [] : games(of: store, bottle: bottle)
        }
        var stores: Set<StoreScreenshots.Source> = []
        let changed = try GameLibrary.modify(paths.library) { library in
            let changed = merge(found, into: &library, now: now, retina: SharedSettings.newGameRetina(paths: paths))
            stores = Set(library.games.compactMap(StoreScreenshots.Source.init))
            return changed
        }
        StoreScreenshots.prune(keeping: stores, paths: paths)
        return changed
    }

    /// The pure part of `sync`.
    /// - Parameters:
    ///   - retina: the Retina setting a newly found game gets (`SharedSettings.newGameRetina`).
    ///   - stillThere: a game the scan missed that is still installed all the same; it stays.
    static func merge(_ found: [Store: [Game]], into library: inout GameLibrary, now: Date,
                      retina: GameScaling.Setting? = nil,
                      stillThere: (GameRecord) -> Bool = stillInstalled) -> Bool {
        var changed = false
        let before = library.games
        library.games.removeAll { record in
            guard let store = record.store else { return false }
            return !(found[store] ?? []).contains { $0.id == record.storeID } && !stillThere(record)
        }
        changed = library.games.count != before.count
        for (store, games) in found {
            for game in games {
                let existing = library.games.firstIndex { $0.store == store && $0.storeID == game.id }
                let folder = game.folder.path(percentEncoded: false)
                if let index = existing {
                    var record = library.games[index]
                    record.name = game.name
                    record.folder = folder
                    // A program the store names wins over one Magic Kettle picked, and a picked one stays while it
                    // exists.
                    if let exe = game.executable?.path(percentEncoded: false), exe != record.executable {
                        record.executable = exe
                    } else if !FileManager.default.fileExists(atPath: record.executable),
                              let exe = mainProgram(of: game) {
                        record.executable = exe.path(percentEncoded: false)
                    }
                    if record != library.games[index] {
                        library.games[index] = record
                        changed = true
                    }
                } else if let exe = game.executable ?? mainProgram(of: game) {
                    var record = GameRecord(id: .make(), name: game.name, executable: exe.path(percentEncoded: false),
                                            folder: folder, hasMarker: false, addedAt: now)
                    record.store = store
                    record.storeID = game.id
                    record.retina = retina
                    library.games.append(record)
                    changed = true
                }
            }
        }
        return changed
    }

    /// A game its store says is still installed although the scan missed it (`StoreModule.stillInstalled`). A
    /// store whose client was removed takes its games with it.
    static func stillInstalled(_ record: GameRecord) -> Bool {
        record.store?.module.stillInstalled(record) ?? false
    }

    /// The program that starts the game, picked like after an install: named like the game, else the biggest.
    static func mainProgram(of game: Game) -> URL? {
        let found = InstalledPrograms.find(in: [game.folder], shortcutTargets: [], name: game.name)
        return found.recommended?.url ?? found.programs.first?.url
    }
}
