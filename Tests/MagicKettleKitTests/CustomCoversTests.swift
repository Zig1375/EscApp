import CoreGraphics
import Foundation
import ImageIO
@testable import MagicKettleKit
import Testing
import UniformTypeIdentifiers

@Suite struct CustomCoversTests {
    private func png(at url: URL) throws {
        let context = try #require(CGContext(data: nil, width: 6, height: 9, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                                       1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func setReplaceAndRemove() throws {
        let temp = try TempFolder()
        let paths = AppPaths(root: temp.url, games: temp.url.appending(path: "Games"))
        let game = GameID.make()
        #expect(CustomCovers.cover(for: game, paths: paths) == nil)

        let first = temp.url.appending(path: "Cover.PNG")
        try png(at: first)
        let kept = try CustomCovers.set(first, for: game, paths: paths)
        #expect(kept.lastPathComponent == "cover-\(game.rawValue).png")
        // A copy: the original can go.
        try FileManager.default.removeItem(at: first)
        #expect(CustomCovers.cover(for: game, paths: paths)?.lastPathComponent == kept.lastPathComponent)

        let second = temp.url.appending(path: "other.jpeg")
        try png(at: second)
        try CustomCovers.set(second, for: game, paths: paths)
        #expect(CustomCovers.cover(for: game, paths: paths)?.lastPathComponent == "cover-\(game.rawValue).jpeg")
        #expect(!FileManager.default.fileExists(atPath: kept.path))

        CustomCovers.remove(for: game, paths: paths)
        #expect(CustomCovers.cover(for: game, paths: paths) == nil)
    }

    @Test func notAnImageIsRefused() throws {
        let temp = try TempFolder()
        let paths = AppPaths(root: temp.url, games: temp.url.appending(path: "Games"))
        let text = temp.url.appending(path: "notes.png")
        try Data("hello".utf8).write(to: text)
        #expect(throws: CustomCovers.CoverError.notAnImage) {
            try CustomCovers.set(text, for: GameID.make(), paths: paths)
        }
    }

    @Test func pruneKeepsOnlyLibraryGames() throws {
        let temp = try TempFolder()
        let paths = AppPaths(root: temp.url, games: temp.url.appending(path: "Games"))
        let picture = temp.url.appending(path: "c.png")
        try png(at: picture)
        let (kept, gone) = (GameID.make(), GameID.make())
        try CustomCovers.set(picture, for: kept, paths: paths)
        try CustomCovers.set(picture, for: gone, paths: paths)
        try Data().write(to: paths.artwork.appending(path: "steam-400"))

        CustomCovers.prune(keeping: [kept], paths: paths)
        #expect(CustomCovers.cover(for: kept, paths: paths) != nil)
        #expect(CustomCovers.cover(for: gone, paths: paths) == nil)
        // Steam's screenshots live in the same folder and aren't touched.
        #expect(FileManager.default.fileExists(atPath: paths.artwork.appending(path: "steam-400").path))
    }
}
