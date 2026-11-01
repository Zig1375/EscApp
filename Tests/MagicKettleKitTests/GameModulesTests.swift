import Foundation
@testable import MagicKettleKit
import Testing

@Suite struct GameModulesTests {
    static let epicID = "61449320f87347a8bf02159cbf8adb7f:36b11de2ebd3409f9a4435619dfa0fea:Salmon"

    func module(_ id: String, match: GameModule.Match, requires: GameModule.Requires? = nil,
                fixes: [GameModule.Group]) -> GameModule {
        GameModule(id: id, revision: 1, format: 1, name: id, match: match, requires: requires, fixes: fixes)
    }

    func prefer(_ backends: [String], when: GameModule.When? = nil) -> GameModule.Group {
        GameModule.Group(when: when, launch: GameModule.Launch(prefer: GameModule.Settings(backend: backends)))
    }

    func game(store: Store? = nil, storeID: String? = nil, exe: String = "/g/Before We Leave.exe",
              product: String? = nil) -> GameModules.Game {
        GameModules.Game(store: store, storeID: storeID, executable: URL(filePath: exe), productName: product)
    }

    let wine = Version("11.20")!

    // MARK: The index

    /// The app's copy of the index decodes, and has the module Before We Leave needs: DXMT, whatever was
    /// remembered.
    @Test func bundledIndexHasBeforeWeLeave() throws {
        let index = try GameModuleIndex.bundled()
        #expect(index.format == 1)
        let found = GameModules.find(for: game(store: .epic, storeID: Self.epicID), in: index.modules, app: nil)
        #expect(found?.id == "before-we-leave")
        let launch = try GameModules.launch(of: try #require(found), store: .epic, wine: wine)
        #expect(launch.requireBackend == .dxmt)
    }

    /// One module covers every copy of the game: each store's own id, and the exe's name for a copy from a store
    /// the module doesn't list or from no store at all.
    @Test func bundledModuleCoversEveryCopy() throws {
        let modules = try GameModuleIndex.bundled().modules
        let copies = [
            game(store: .epic, storeID: Self.epicID, exe: "/g/Other.exe"),
            game(store: .steam, storeID: "1073910", exe: "/g/Other.exe"),
            game(store: .steam, storeID: "1"),
            game(),
        ]
        for copy in copies {
            #expect(GameModules.find(for: copy, in: modules, app: nil)?.id == "before-we-leave")
        }
    }

    /// A module that doesn't decode costs only itself; one in a newer format is decoded but never matched.
    @Test func brokenModuleIsLeftOut() throws {
        let json = """
            {"format": 1, "generated": "2026-10-27T18:22:57Z", "modules": [
              {"id": "broken", "revision": "one"},
              {"id": "newer", "revision": 1, "format": 2, "name": "Newer", "match": {"steam": ["7"]}, "fixes": []},
              {"id": "good", "revision": 2, "format": 1, "name": "Good", "note": "Why.",
               "match": {"steam": ["5"]},
               "fixes": [{"launch": {"require": {"backend": "wined3d", "windows": "win7"}, "arguments": ["-x"]},
                          "registry": [{"key": "HKCU\\\\Software\\\\A", "name": "B", "dword": 1}]}]}
            ]}
            """
        let index = try GameModuleIndex.decode(Data(json.utf8))
        #expect(index.modules.map(\.id) == ["newer", "good"])
        #expect(GameModules.find(for: game(store: .steam, storeID: "7"), in: index.modules, app: nil) == nil)
        let good = try #require(GameModules.find(for: game(store: .steam, storeID: "5"), in: index.modules, app: nil))
        let launch = try GameModules.launch(of: good, store: .steam, wine: wine)
        #expect(launch.requireBackend == .wined3d)
        #expect(launch.requireWindows == .windows7)
    }

    /// The newer of the app's copy and the download wins, so an app update with newer modules isn't undone by
    /// yesterday's download.
    @Test func newerIndexWins() {
        let old = GameModuleIndex(generated: Date(timeIntervalSince1970: 100), modules: [])
        let new = GameModuleIndex(generated: Date(timeIntervalSince1970: 200), modules: [])
        #expect(GameModulesUpdater.choose(bundled: old, cached: new) == new)
        #expect(GameModulesUpdater.choose(bundled: new, cached: old) == new)
        #expect(GameModulesUpdater.choose(bundled: nil, cached: old) == old)
        #expect(GameModulesUpdater.choose(bundled: old, cached: nil) == old)
    }

    // MARK: Finding a game's module

    @Test func storeIDComesFirst() {
        let byName = module("by-name", match: .init(exe: [.init(name: "Before We Leave.exe")]), fixes: [])
        let byStore = module("by-store", match: .init(epic: [Self.epicID]), fixes: [])
        let modules = [byName, byStore]
        #expect(GameModules.find(for: game(store: .epic, storeID: Self.epicID), in: modules, app: nil)?.id
            == "by-store")
        // The same exe without a store is found by its name.
        #expect(GameModules.find(for: game(), in: modules, app: nil)?.id == "by-name")
        // A Steam id never matches an Epic one.
        #expect(GameModules.find(for: game(store: .steam, storeID: Self.epicID, exe: "/g/other.exe"),
                                 in: modules, app: nil) == nil)
    }

    @Test func exeByHashThenProductThenName() {
        let hash = String(repeating: "ab", count: 32)
        let modules = [
            module("plain", match: .init(exe: [.init(name: "Game.exe")]), fixes: []),
            module("product", match: .init(exe: [.init(name: "game.EXE", product: "Real Game")]), fixes: []),
            module("hash", match: .init(exe: [.init(name: "Game.exe", sha256: [hash])]), fixes: []),
        ]
        let exe = "/g/Game.exe"
        #expect(GameModules.find(for: game(exe: exe, product: "Real Game"), in: modules, app: nil,
                                 sha256: { hash.uppercased() })?.id == "hash")
        #expect(GameModules.find(for: game(exe: exe, product: " real game "), in: modules, app: nil)?.id
            == "product")
        #expect(GameModules.find(for: game(exe: exe, product: "Other"), in: modules, app: nil)?.id == "plain")
    }

    /// The exe is hashed only when some module names a hash for its file name: hashing a 2 GB exe for nothing
    /// would slow every launch.
    @Test func hashesOnlyWhenAsked() {
        var asked = false
        let modules = [module("plain", match: .init(exe: [.init(name: "Game.exe")]), fixes: [])]
        _ = GameModules.find(for: game(exe: "/g/Other.exe"), in: modules, app: nil) {
            asked = true
            return nil
        }
        #expect(!asked)
    }

    @Test func newerAppOnly() {
        let needsNew = module("new", match: .init(steam: ["1"]), requires: .init(minApp: "2.0"), fixes: [])
        let found = { (app: Version?) in
            GameModules.find(for: game(store: .steam, storeID: "1"), in: [needsNew], app: app)
        }
        #expect(found(Version("1.9")) == nil)
        #expect(found(Version("2.0"))?.id == "new")
        #expect(found(nil)?.id == "new")
    }

    // MARK: What a module does to a launch

    @Test func conditionsDecideTheGroups() throws {
        let groups = [
            prefer(["dxvk"]),
            prefer(["wined3d"], when: .init(wine: .init(below: "11.20"))),
            prefer(["dxmt", "dxvk"], when: .init(store: ["epic"])),
            // Decided only once the backend is known: never for the order.
            prefer(["wined3d"], when: .init(backend: ["dxmt"])),
        ]
        let subject = module("m", match: .init(steam: ["1"]), fixes: groups)
        #expect(try GameModules.launch(of: subject, store: .epic, wine: wine).preferBackends == [.dxmt, .dxvk])
        #expect(try GameModules.launch(of: subject, store: nil, wine: wine).preferBackends == [.dxvk])
        #expect(try GameModules.launch(of: subject, store: nil, wine: Version("11.0")!).preferBackends == [.wined3d])
    }

    @Test func otherWineIsNotApplied() {
        let subject = module("m", match: .init(steam: ["1"]), requires: .init(wine: .init(from: "12.0")),
                             fixes: [prefer(["dxmt"])])
        #expect(throws: GameModules.Skip.wine(installed: wine)) {
            try GameModules.launch(of: subject, store: nil, wine: wine)
        }
    }

    @Test func unknownValuesAreSkipped() throws {
        let subject = module("m", match: .init(steam: ["1"]), fixes: [prefer(["metal4", "dxmt"])])
        #expect(try GameModules.launch(of: subject, store: nil, wine: wine).preferBackends == [.dxmt])
    }

    @Test func wineVersionOfARuntime() throws {
        let runtime = try #require(RuntimeManifest.bundled().runtimes.last)
        #expect(GameModules.wineVersion(of: runtime) >= Version("11.0")!)
    }

    // MARK: The order of backends

    func record(store: Store? = .epic) -> GameRecord {
        var record = GameRecord(id: GameID.make(), name: "Before We Leave", executable: "/g/Before We Leave.exe",
                                folder: "/g/", hasMarker: false, addedAt: Date())
        record.store = store
        return record
    }

    let unity = ExecutableInfo(format: .pe64, imports: ["kernel32.dll", "unityplayer.dll"], productName: nil,
                               icon: nil, dpiAware: false)

    /// Before We Leave from Epic: with its module DXMT comes first, not DXVK's black window. A store game is
    /// searched for like any other.
    @Test func preferLeadsTheStoreGamesSearch() {
        var launch = GameModules.Launch()
        #expect(AutoLaunch.order(for: record(), override: nil, info: unity, recommended: nil, known: nil,
                                 module: launch) == [.dxvk, .dxmt])
        launch.preferBackends = [.dxmt]
        #expect(AutoLaunch.order(for: record(), override: nil, info: unity, recommended: nil, known: nil,
                                 module: launch) == [.dxmt, .dxvk])
        #expect(AutoLaunch.order(for: record(store: nil), override: nil, info: unity, recommended: nil, known: nil,
                                 module: launch) == [.dxmt, .dxvk, .wined3d])
    }

    /// Steam's window doesn't start on plain Wine, so a store game skips WineD3D; D3DMetal, once added, comes last.
    @Test func storeGamesSkipWineD3DAndTryD3DMetal() {
        #expect(AutoLaunch.order(for: record(store: .steam), override: nil, info: unity, recommended: nil, known: nil,
                                 d3dmetal: true) == [.dxvk, .dxmt, .d3dmetal])
        #expect(AutoLaunch.order(for: record(store: nil), override: nil, info: unity, recommended: nil, known: nil,
                                 d3dmetal: true) == [.dxvk, .dxmt, .wined3d])
    }

    /// The player's choice beats `require`, `require` beats what worked here, and that beats `prefer`.
    @Test func priorities() {
        var launch = GameModules.Launch()
        launch.preferBackends = [.dxmt]
        var game = record(store: nil)
        game.backend = .wined3d
        #expect(AutoLaunch.order(for: game, override: nil, info: unity, recommended: nil, known: nil,
                                 module: launch) == [.wined3d])
        launch.requireBackend = .dxvk
        #expect(AutoLaunch.order(for: game, override: nil, info: unity, recommended: nil, known: nil,
                                 module: launch) == [.dxvk])
        game.chosenBackend = .dxmt
        #expect(AutoLaunch.order(for: game, override: nil, info: unity, recommended: nil, known: nil,
                                 module: launch) == [.dxmt])
    }

    @Test func preferComesBeforeTheFoldersRecommendation() {
        #expect(BackendPlan.order([.dxvk, .dxmt, .wined3d], remembered: nil, preferred: [.wined3d],
                                  recommended: .dxmt, known: nil) == [.wined3d, .dxmt, .dxvk])
    }
}
