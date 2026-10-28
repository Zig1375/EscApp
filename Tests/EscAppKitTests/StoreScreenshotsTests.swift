@testable import EscAppKit
import Foundation
import Testing

@Suite struct StoreScreenshotsTests {
    let base = "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/242920/"
    let namespace = "61449320f87347a8bf02159cbf8adb7f"

    func game(store: Store?, id: String?, name: String = "Before We Leave") -> GameRecord {
        var game = GameRecord(id: .make(), name: name, executable: "/g.exe", folder: "/", hasMarker: false,
                              addedAt: Date())
        game.store = store
        game.storeID = id
        return game
    }

    @Test func sourceOfEachStore() {
        #expect(StoreScreenshots.Source(game(store: .steam, id: "242920")) == .steam(appID: "242920"))
        #expect(StoreScreenshots.Source(game(store: .epic, id: "\(namespace):36b11de2ebd3409f9a4435619dfa0fea:Wren"))
            == .epic(namespace: namespace, title: "Before We Leave"))
        // An Epic game recorded by its app name alone has no catalog namespace to find its page by.
        #expect(StoreScreenshots.Source(game(store: .epic, id: "Wren")) == nil)
        #expect(StoreScreenshots.Source(game(store: nil, id: nil)) == nil)
    }

    @Test func foldersNeverLeaveArtwork() {
        let paths = AppPaths(root: URL(filePath: "/x"), games: URL(filePath: "/x"))
        #expect(StoreScreenshots.folder(.steam(appID: "242920"), paths: paths)?.lastPathComponent == "steam-242920")
        #expect(StoreScreenshots.folder(.epic(namespace: namespace, title: ""), paths: paths)?.lastPathComponent
            == "epic-\(namespace)")
        #expect(StoreScreenshots.folder(.steam(appID: "../1"), paths: paths) == nil)
        #expect(StoreScreenshots.folder(.epic(namespace: "../a", title: ""), paths: paths) == nil)
    }

    @Test func keptListIsUsedWhileFresh() async throws {
        let temp = try TempFolder()
        let paths = AppPaths(root: temp.url, games: temp.url.appending(path: "Games"))
        let shot = StoreScreenshots.Shot(id: 1, thumbnail: URL(string: "\(base)t.jpg")!,
                                         full: URL(string: "\(base)f.jpg")!)
        let source = StoreScreenshots.Source.steam(appID: "242920")
        let folder = try #require(StoreScreenshots.folder(source, paths: paths))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode([shot]).write(to: folder.appending(path: "screenshots.json"))
        #expect(StoreScreenshots.cached(source, paths: paths) == [shot])
        // Fresh: no request.
        #expect(await StoreScreenshots.load(source, paths: paths) == [shot])
    }

    @Test func picturesOfGamesNoLongerThereGo() throws {
        let temp = try TempFolder()
        let paths = AppPaths(root: temp.url, games: temp.url.appending(path: "Games"))
        let sources: [StoreScreenshots.Source] = [.steam(appID: "242920"), .steam(appID: "400"),
                                                  .epic(namespace: namespace, title: ""),
                                                  .epic(namespace: "crab", title: "")]
        for source in sources {
            let folder = try #require(StoreScreenshots.folder(source, paths: paths))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appending(path: "a.jpg"))
        }
        let other = paths.artwork.appending(path: "cover-\(GameID.make().rawValue).png")
        try Data("x".utf8).write(to: other)

        // The title doesn't matter: the folder is the namespace's.
        StoreScreenshots.prune(keeping: [.steam(appID: "242920"), .epic(namespace: namespace, title: "Other")],
                               paths: paths)
        let left = try FileManager.default.contentsOfDirectory(atPath: paths.artwork.path).sorted()
        // Only its own folders: a cover the player chose stays.
        #expect(left == [other.lastPathComponent, "epic-\(namespace)", "steam-242920"].sorted())
    }

    @Test func noArtworkFolderIsFine() throws {
        let temp = try TempFolder()
        StoreScreenshots.prune(keeping: [], paths: AppPaths(root: temp.url, games: temp.url))
    }
}

@Suite struct EpicScreenshotsTests {
    let namespace = "61449320f87347a8bf02159cbf8adb7f"
    let cdn = "https://cdn2.unrealengine.com/"

    @Test func slugFromName() {
        #expect(EpicScreenshots.slug(title: "Before We Leave") == "before-we-leave")
        #expect(EpicScreenshots.slug(title: "Assassin's Creed® Unity") == "assassins-creed-unity")
        #expect(EpicScreenshots.slug(title: "Pokémon: Edition - Two") == "pokemon-edition-two")
        #expect(EpicScreenshots.slug(title: "  ") == "")
    }

    @Test func listedSlugFirstThenTheName() {
        let mapping = Data(#"{"fn":"fortnite","\#(namespace)":"before-we-leave-x"}"#.utf8)
        #expect(EpicScreenshots.slugs(namespace: namespace, title: "Before We Leave", mapping: mapping)
            == ["before-we-leave-x", "before-we-leave"])
        #expect(EpicScreenshots.slugs(namespace: "fn", title: "Fortnite", mapping: mapping) == ["fortnite"])
        #expect(EpicScreenshots.slugs(namespace: namespace, title: "Before We Leave", mapping: nil)
            == ["before-we-leave"])
        #expect(EpicScreenshots.slugs(namespace: namespace, title: "™", mapping: Data("<html>".utf8)) == [])
    }

    @Test func productRequestTakesOnlyASlug() {
        #expect(EpicScreenshots.product(slug: "before-we-leave")?.absoluteString
            == "https://store-content-ipv4.ak.epicgames.com/api/en-US/content/products/before-we-leave")
        #expect(EpicScreenshots.product(slug: "../x") == nil)
        #expect(EpicScreenshots.product(slug: "a?b=c") == nil)
        #expect(EpicScreenshots.product(slug: "") == nil)
    }

    func page(namespace: String) -> Data {
        Data("""
            {"namespace":"\(namespace)","pages":[{"type":"productHome","namespace":"\(namespace)","data":{"carousel":{
              "items":[
                {"image":{"_type":"Diesel Image"},"video":{"type":"epicHosted"}},
                {"image":{"src":"\(cdn)g1a-02-1920x1080.jpg"},"video":{}},
                {"image":{"src":"https://evil.example/a.jpg"}},
                {"image":{"src":"http://cdn2.unrealengine.com/b.jpg"}},
                {"image":{"src":"https://cdn1.epicgames.com/x/item/c.jpg"}}
              ]},"gallery":{"galleryImages":[{"src":"\(cdn)banner-1013x200.jpg"}]}}}]}
            """.utf8)
    }

    @Test func carouselPicturesParse() throws {
        let shots = try #require(EpicScreenshots.parse(page(namespace: namespace), namespace: namespace))
        // Videos and pictures from anywhere but Epic's servers, over https, are left out.
        #expect(shots.map(\.full.absoluteString) == ["\(cdn)g1a-02-1920x1080.jpg",
                                                     "https://cdn1.epicgames.com/x/item/c.jpg"])
        #expect(shots.map(\.id) == [0, 1])
        #expect(shots[0].thumbnail.absoluteString
            == "\(cdn)g1a-02-1920x1080.jpg?resize=1&w=640&h=360&quality=medium")
    }

    @Test func anotherGamesPageIsRefused() {
        #expect(EpicScreenshots.parse(page(namespace: "crab"), namespace: namespace) == nil)
        #expect(EpicScreenshots.parse(Data("<html>".utf8), namespace: namespace) == nil)
        #expect(EpicScreenshots.parse(Data(#"{"namespace":"\#(namespace)","pages":[]}"#.utf8), namespace: namespace)
            == [])
    }

    @Test func epicHosts() {
        #expect(EpicScreenshots.isEpics(URL(string: "https://cdn1.epicgames.com/a.jpg")!))
        #expect(EpicScreenshots.isEpics(URL(string: "https://cdn2.unrealengine.com/a.jpg")!))
        #expect(!EpicScreenshots.isEpics(URL(string: "https://notepicgames.com/a.jpg")!))
        #expect(!EpicScreenshots.isEpics(URL(string: "http://cdn1.epicgames.com/a.jpg")!))
    }
}

@Suite struct EpicCoversTests {
    let namespace = "61449320f87347a8bf02159cbf8adb7f"
    let item = "36b11de2ebd3409f9a4435619dfa0fea"

    func catalog(_ json: String) -> Data {
        // The launcher wraps the base64 in lines.
        Data(json.utf8).base64EncodedData(options: .lineLength76Characters)
    }

    @Test func tallCoverOfTheItem() {
        let data = catalog("""
            [{"id":"other","namespace":"\(namespace)","keyImages":[
              {"type":"DieselGameBoxTall","url":"https://cdn1.epicgames.com/x/other.jpg"}]},
             {"id":"\(item)","namespace":"\(namespace)","title":"Before We Leave","keyImages":[
              {"type":"DieselGameBox","url":"https://cdn1.epicgames.com/x/wide.jpg","width":1360},
              {"type":"DieselGameBoxTall","url":"https://cdn1.epicgames.com/x/tall.jpg","width":510}]}]
            """)
        #expect(EpicCovers.coverURL(catalog: data, item: item)?.absoluteString
            == "https://cdn1.epicgames.com/x/tall.jpg")
    }

    @Test func noTallCoverOrNotEpics() {
        let wide = catalog(#"[{"id":"\#(item)","keyImages":[{"type":"DieselGameBox","url":"https://epicgames.com"}]}]"#)
        #expect(EpicCovers.coverURL(catalog: wide, item: item) == nil)
        let evil = catalog(#"[{"id":"\#(item)","keyImages":[{"type":"DieselGameBoxTall","url":"https://evil.x/t"}]}]"#)
        #expect(EpicCovers.coverURL(catalog: evil, item: item) == nil)
        #expect(EpicCovers.coverURL(catalog: Data("not base64 json".utf8), item: item) == nil)
    }

    @Test func keptCoverIsUsedWithoutTheLauncher() async throws {
        let temp = try TempFolder()
        let paths = AppPaths(root: temp.url, games: temp.url.appending(path: "Games"))
        let storeID = "\(namespace):\(item):Wren"
        #expect(EpicCovers.cached(storeID: storeID, paths: paths) == nil)
        let file = try #require(EpicCovers.file(namespace: namespace, paths: paths))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: file)
        #expect(EpicCovers.cached(storeID: storeID, paths: paths) == file)
        let noBottle = temp.url.appending(path: "nothing")
        #expect(await EpicCovers.cover(storeID: storeID, bottle: noBottle, paths: paths) == file)
    }
}
