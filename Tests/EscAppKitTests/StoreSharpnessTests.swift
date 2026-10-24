@testable import EscAppKit
import Foundation
import Testing

@Suite struct StoreSharpnessTests {
    @Test func storeClientsDrawAtTheScreensResolution() throws {
        let temp = try TempFolder()
        let userReg = temp.url.appending(path: "user.reg")
        try "WINE REGISTRY Version 2\n".write(to: userReg, atomically: true, encoding: .utf8)

        try StoreClient.drawSharp(temp.url, scale: 2)
        var text = try String(contentsOf: userReg, encoding: .utf8)
        #expect(WineRegistry.string(in: text, key: #"Software\Wine\Mac Driver"#, name: "RetinaMode") == "y")
        #expect(WineRegistry.contains(text, key: #"Control Panel\Desktop"#, entry: #""LogPixels"=dword:000000c0"#))

        // A display without Retina: Wine's defaults, or everything would be drawn twice as large.
        try StoreClient.drawSharp(temp.url, scale: 1)
        text = try String(contentsOf: userReg, encoding: .utf8)
        #expect(WineRegistry.string(in: text, key: #"Software\Wine\Mac Driver"#, name: "RetinaMode") == "n")
        #expect(WineRegistry.contains(text, key: #"Control Panel\Desktop"#, entry: #""LogPixels"=dword:00000060"#))
    }
}
