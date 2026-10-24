@testable import EscAppKit
import Foundation
import Testing

@Suite struct SteamCoversTests {
    let steam: URL

    init() throws {
        steam = FileManager.default.temporaryDirectory.appending(path: "SteamCovers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: steam.appending(path: "appcache/librarycache"),
                                                withIntermediateDirectories: true)
    }

    private func put(_ path: String) throws {
        let file = steam.appending(path: "appcache/librarycache/\(path)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0xD8]).write(to: file)
    }

    @Test func coverInTheGamesFolder() throws {
        defer { try? FileManager.default.removeItem(at: steam) }
        try put("242920/library_600x900.jpg")
        try put("242920/header.jpg")
        #expect(SteamCovers.cover(appID: "242920", steamFolder: steam)?.lastPathComponent == "library_600x900.jpg")
    }

    @Test func coverInAHashFolder() throws {
        defer { try? FileManager.default.removeItem(at: steam) }
        try put("220/ac2f074d/library_600x900.jpg")
        try put("220/header.jpg")
        let cover = try #require(SteamCovers.cover(appID: "220", steamFolder: steam))
        #expect(cover.path.hasSuffix("220/ac2f074d/library_600x900.jpg"))
    }

    @Test func oldFlatLayout() throws {
        defer { try? FileManager.default.removeItem(at: steam) }
        try put("400_library_600x900.jpg")
        #expect(SteamCovers.cover(appID: "400", steamFolder: steam)?.lastPathComponent == "400_library_600x900.jpg")
    }

    @Test func noCoverOrBadID() throws {
        defer { try? FileManager.default.removeItem(at: steam) }
        try put("10/header.jpg")
        #expect(SteamCovers.cover(appID: "10", steamFolder: steam) == nil)
        #expect(SteamCovers.cover(appID: "../10", steamFolder: steam) == nil)
        #expect(SteamCovers.cover(appID: "", steamFolder: steam) == nil)
    }
}
