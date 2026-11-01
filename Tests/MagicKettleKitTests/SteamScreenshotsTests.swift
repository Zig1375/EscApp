import Foundation
@testable import MagicKettleKit
import Testing

@Suite struct SteamScreenshotsTests {
    let base = "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/242920/"

    @Test func storeAnswerParses() throws {
        let json = """
            {"242920":{"success":true,"data":{"screenshots":[
              {"id":0,"path_thumbnail":"\(base)ss_a.600x338.jpg?t=1","path_full":"\(base)ss_a.1920x1080.jpg?t=1"},
              {"id":6,"path_thumbnail":"https://evil.example/ss_b.jpg","path_full":"\(base)ss_b.1920x1080.jpg"},
              {"id":7,"path_thumbnail":"http://cdn.steamstatic.com/ss_c.jpg","path_full":"\(base)ss_c.jpg"}
            ]}}}
            """
        let shots = try #require(SteamScreenshots.parse(Data(json.utf8), appID: "242920"))
        // Only pictures from Steam's own servers, over https.
        #expect(shots == [.init(id: 0, thumbnail: URL(string: "\(base)ss_a.600x338.jpg?t=1")!,
                                full: URL(string: "\(base)ss_a.1920x1080.jpg?t=1")!)])
    }

    @Test func gameWithoutScreenshotsOrUnknown() {
        #expect(SteamScreenshots.parse(Data(#"{"1":{"success":true,"data":{}}}"#.utf8), appID: "1") == [])
        #expect(SteamScreenshots.parse(Data(#"{"1":{"success":false}}"#.utf8), appID: "1") == nil)
        #expect(SteamScreenshots.parse(Data("<html>".utf8), appID: "1") == nil)
    }

    @Test func requestNamesOnlyTheAppID() {
        #expect(SteamScreenshots.request(appID: "242920")?.absoluteString
            == "https://store.steampowered.com/api/appdetails?appids=242920&filters=screenshots")
        #expect(SteamScreenshots.request(appID: "1&x=2") == nil)
        #expect(SteamScreenshots.request(appID: "") == nil)
    }

    @Test func steamHosts() {
        #expect(SteamScreenshots.isSteams(URL(string: "https://cdn.akamai.steamstatic.com/a.jpg")!))
        #expect(SteamScreenshots.isSteams(URL(string: "https://steamcdn-a.akamaihd.net/a.jpg")!))
        #expect(!SteamScreenshots.isSteams(URL(string: "https://notsteamstatic.com/a.jpg")!))
        #expect(!SteamScreenshots.isSteams(URL(string: "http://cdn.steamstatic.com/a.jpg")!))
    }
}
