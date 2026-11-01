import Foundation
@testable import MagicKettleKit
import Testing

@Suite struct RPGMakerGameTests {
    static func shiftJIS(_ text: String) -> Data {
        // Windows line ends, as the games ship them.
        // swiftlint:disable:next force_unwrapping
        text.replacingOccurrences(of: "\n", with: "\r\n").data(using: .shiftJIS)!
    }

    @Test func aVXGameNamesItsPackage() {
        // "Let's Do The Goodfeeling Wife! RPG": Shift-JIS, a Japanese title, the engine from the RTP.
        let ini = Self.shiftJIS("""
            [Game]
            RTP=RPGVX
            Library=RGSS200J.dll
            Scripts=Data\\Scripts.rvdata
            Title=気持ちいい人妻とハメハメしよう！ＲＰＧ
            """)
        #expect(RPGMakerGame.parse(ini: ini) == RPGMakerGame(engine: .rgss2, rtps: ["RPGVX"]))
    }

    @Test func anXPGameListsUpToThreePackages() {
        let ini = Data("[Game]\nLibrary=RGSS103J.dll\nTitle=Project5\nRTP1=Standard\nRTP2=\nRTP3=\n".utf8)
        #expect(RPGMakerGame.parse(ini: ini) == RPGMakerGame(engine: .rgss1, rtps: ["Standard"]))
    }

    @Test func aVXAceGameCarryingItsEngineMayNeedNoPackage() {
        let carried = Data("[Game]\nLibrary=System\\RGSS301.dll\nScripts=Data\\Scripts.rvdata2\nRTP=\n".utf8)
        #expect(RPGMakerGame.parse(ini: carried) == RPGMakerGame(engine: .rgss3, rtps: []))
        let named = Data("[Game]\nRTP=RPGVXAce\nLibrary=System\\RGSS301.dll\n[AudioVol]\nRTP=Other\n".utf8)
        #expect(RPGMakerGame.parse(ini: named) == RPGMakerGame(engine: .rgss3, rtps: ["RPGVXAce"]))
    }

    @Test func otherEnginesGameIniIsNotRPGMakers() {
        // Wolf RPG Editor's "In By Side": window settings, no [Game] section.
        #expect(RPGMakerGame.parse(ini: Data("Start=0\nWindowModeFlag=1\n".utf8)) == nil)
        #expect(RPGMakerGame.parse(ini: Data("[Game]\nLibrary=SomethingElse.dll\n".utf8)) == nil)
    }
}

@Suite struct GameLanguageTests {
    @Test func aShiftJISTitleMakesTheGameJapanese() {
        let ini = RPGMakerGameTests.shiftJIS("[Game]\nTitle=気持ちいい人妻とハメハメしよう！ＲＰＧ\n")
        #expect(GameLanguage.isJapanese(iniFiles: [ini], fileNames: ["Game.exe"]))
    }

    @Test func japaneseFileNamesCountWhenTheIniIsPlainASCII() {
        let ini = Data("[Game]\nTitle=Project5\n".utf8)
        #expect(GameLanguage.isJapanese(iniFiles: [ini], fileNames: ["Game.exe", "はじめにお読みください。.txt"]))
        #expect(!GameLanguage.isJapanese(iniFiles: [ini], fileNames: ["Game.exe", "readme.txt"]))
    }

    @Test func aRussianTranslationStaysInItsOwnCodePage() throws {
        // Code page 1251 read as Shift-JIS lands in half-width katakana and kanji, never in full-width kana.
        let ini = try #require("[Game]\nTitle=Мой перевод\n".data(using: .windowsCP1251))
        #expect(!GameLanguage.isJapanese(iniFiles: [ini], fileNames: ["Game.exe", "はじめにお読みください。.txt"]))
    }

    @Test func kanjiAloneCouldBeChinese() {
        #expect(!GameLanguage.isJapanese(iniFiles: [], fileNames: ["游戏说明.txt"]))
        #expect(GameLanguage.isJapanese(iniFiles: [], fileNames: ["妻奪りの宿"]))
    }

    @Test func theLocaleReachesWineAndThePlayerStillWins() {
        let host = ["LANG": "ru_RU.UTF-8", "LC_ALL": "ru_RU.UTF-8"]
        #expect(WineEnvironment.make(host: host, bottle: "/b")["LC_ALL"] == "ru_RU.UTF-8")
        let japanese = WineEnvironment.make(host: host, bottle: "/b", locale: GameLanguage.japaneseLocale)
        #expect(japanese["LC_ALL"] == "ja_JP.UTF-8")
        let player = WineEnvironment.make(host: host, bottle: "/b", extra: ["LC_ALL": "en_US.UTF-8"],
                                          locale: GameLanguage.japaneseLocale)
        #expect(player["LC_ALL"] == "en_US.UTF-8")
    }
}

@Suite struct RTPManifestTests {
    static func manifest(url: String = "https://cdn.tkool.jp/updata/rtp/vx_rtp202.zip", name: String = "RPGVX",
                         setup: String = "RPGVX_RTP202/setup.exe") -> Data {
        Data("""
        {"format": 1, "runtimes": [], "rtps": [
          {"engine": "RGSS2", "name": "\(name)", "version": "2.02", "url": "\(url)",
           "sha256": "\(String(repeating: "a", count: 64))", "size": 10, "license": "Enterbrain RTP EULA",
           "setup": "\(setup)"}]}
        """.utf8)
    }

    @Test func theBundledManifestHasAPackageForEachEngine() throws {
        let manifest = try RuntimeManifest.bundled()
        #expect(manifest.rtp("Standard", engine: .rgss1) != nil)
        #expect(manifest.rtp("rpgvx", engine: .rgss2) != nil)
        #expect(manifest.rtp("RPGVXAce", engine: .rgss3) != nil)
        #expect(manifest.rtp("RPGVX", engine: .rgss3) == nil)
        try ManifestUpdater.validateRemote(manifest)
    }

    @Test(arguments: [("name", "../x"), ("setup", "../setup.exe"), ("url", "http://cdn.tkool.jp/a.zip")])
    func rejectsUnsafeEntries(_ field: String, _ value: String) {
        let data = switch field {
        case "name": Self.manifest(name: value)
        case "setup": Self.manifest(setup: value)
        default: Self.manifest(url: value)
        }
        #expect(throws: ManifestError.self) { try RuntimeManifest.decode(data) }
    }

    @Test func aFetchedListPointsOnlyAtThePublishers() throws {
        try ManifestUpdater.validateRemote(RuntimeManifest.decode(Self.manifest()))
        let elsewhere = try RuntimeManifest.decode(Self.manifest(url: "https://example.com/vx_rtp202.zip"))
        #expect(throws: ManifestError.self) { try ManifestUpdater.validateRemote(elsewhere) }
    }
}

@Suite struct RTPLinkTests {
    /// A 64-bit bottle as far as linking goes: its 32-bit Windows folder and an empty `system.reg`.
    static func bottle(in temp: TempFolder) throws -> URL {
        let bottle = temp.url.appending(path: "Bottles/game", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bottle.appending(path: "drive_c/windows/syswow64"),
                                                withIntermediateDirectories: true)
        try Data("WINE REGISTRY Version 2\n".utf8).write(to: bottle.appending(path: "system.reg"))
        return bottle
    }

    static func package(in temp: TempFolder, engine: String, name: String, dlls: [String]) throws -> URL {
        let folder = AppPaths(root: temp.url, games: temp.url).rtp(engine: engine, name: name)
        try FileManager.default.createDirectory(at: folder.appending(path: "Graphics"),
                                                withIntermediateDirectories: true)
        for dll in dlls { try Data("MZ".utf8).write(to: folder.appending(path: dll)) }
        return folder
    }

    @Test func theGameFindsThePackageWhereItsInstallerPutsIt() throws {
        let temp = try TempFolder()
        let bottle = try Self.bottle(in: temp)
        let rtp = try Self.package(in: temp, engine: "RGSS", name: "Standard", dlls: ["RGSS103J.dll"])

        try RTPInstaller.link(rtp, engine: "RGSS", name: "Standard", into: bottle, registry: true)

        let fileManager = FileManager.default
        let linked = bottle.appending(path: "drive_c/Program Files (x86)/Common Files/Enterbrain/RGSS/Standard")
        #expect(try fileManager.destinationOfSymbolicLink(atPath: linked.path) == rtp.path)
        // XP's loader takes its engine from Windows' folder for 32-bit programs.
        let dll = bottle.appending(path: "drive_c/windows/syswow64/RGSS103J.dll")
        #expect(try fileManager.destinationOfSymbolicLink(atPath: dll.path) == rtp.appending(path: "RGSS103J.dll").path)
        let registry = try String(contentsOf: bottle.appending(path: "system.reg"), encoding: .utf8)
        #expect(WineRegistry.string(in: registry, key: #"Software\Wow6432Node\Enterbrain\RGSS\RTP"#, name: "Standard")
            == #"C:\Program Files (x86)\Common Files\Enterbrain\RGSS\Standard"#)
    }

    @Test func thePlayersOwnFilesStay() throws {
        let temp = try TempFolder()
        let bottle = try Self.bottle(in: temp)
        let rtp = try Self.package(in: temp, engine: "RGSS2", name: "RPGVX", dlls: ["RGSS202E.dll"])
        let fileManager = FileManager.default
        let own = bottle.appending(path: "drive_c/Program Files (x86)/Common Files/Enterbrain/RGSS2/RPGVX")
        try fileManager.createDirectory(at: own, withIntermediateDirectories: true)
        let ownDLL = bottle.appending(path: "drive_c/windows/syswow64/RGSS202E.dll")
        try Data("own".utf8).write(to: ownDLL)

        try RTPInstaller.link(rtp, engine: "RGSS2", name: "RPGVX", into: bottle, registry: false)

        #expect((try? fileManager.destinationOfSymbolicLink(atPath: own.path)) == nil)
        #expect(try Data(contentsOf: ownDLL) == Data("own".utf8))
        // Without `registry` (the bottle's Wine is running) the registry isn't touched.
        let registry = try String(contentsOf: bottle.appending(path: "system.reg"), encoding: .utf8)
        #expect(!registry.contains("Enterbrain"))
    }

    @Test func linkingAgainChangesNothing() throws {
        let temp = try TempFolder()
        let bottle = try Self.bottle(in: temp)
        let rtp = try Self.package(in: temp, engine: "RGSS3", name: "RPGVXAce", dlls: [])
        try RTPInstaller.link(rtp, engine: "RGSS3", name: "RPGVXAce", into: bottle, registry: true)
        let first = try Data(contentsOf: bottle.appending(path: "system.reg"))
        try RTPInstaller.link(rtp, engine: "RGSS3", name: "RPGVXAce", into: bottle, registry: true)
        #expect(try Data(contentsOf: bottle.appending(path: "system.reg")) == first)
    }

    @Test func whatTheInstallerPutDownIsKeptWithoutItsUninstaller() throws {
        let temp = try TempFolder()
        let bottle = try Self.bottle(in: temp)
        let fileManager = FileManager.default
        let installed = bottle.appending(path: "drive_c/Program Files (x86)/Common Files/Enterbrain/RGSS/Standard")
        try fileManager.createDirectory(at: installed.appending(path: "Audio"), withIntermediateDirectories: true)
        try Data().write(to: installed.appending(path: "unins000.exe"))
        try Data().write(to: bottle.appending(path: "drive_c/windows/syswow64/RGSS104E.dll"))
        try Data().write(to: bottle.appending(path: "drive_c/windows/syswow64/kernel32.dll"))
        let rtp = try RuntimeManifest.decode(RTPManifestTests.manifest()).rtps?.first
        var standard = try #require(rtp)
        standard.engine = "RGSS"
        standard.name = "Standard"
        let kept = temp.url.appending(path: "kept", directoryHint: .isDirectory)

        #expect(try RTPInstaller.collect(standard, from: bottle, into: kept))

        #expect(try fileManager.contentsOfDirectory(atPath: kept.path).sorted() == ["Audio", "RGSS104E.dll"])
        standard.name = "Missing"
        #expect(try !RTPInstaller.collect(standard, from: bottle, into: temp.url.appending(path: "none")))
    }
}

@Suite struct JapaneseFontTests {
    @Test func nonASCIINamesAreWrittenAndReadTheWayWineDoes() {
        let key = #"Software\Wine\Fonts\Replacements"#
        let text = WineRegistry.setString(in: "WINE REGISTRY Version 2\n", key: key, name: "ＭＳ Ｐゴシック",
                                          value: "Arial Unicode MS")
        #expect(text.contains(#""\xff2d\xff33 \xff30\x30b4\x30b7\x30c3\x30af"="Arial Unicode MS""#))
        #expect(WineRegistry.string(in: text, key: key, name: "ＭＳ Ｐゴシック") == "Arial Unicode MS")
        // As Wine itself wrote the RPG Maker VX package's name: shorter escapes when no hex digit follows.
        let wine = "[Software\\\\Uninstall]\n\"DisplayName\"=\"RPG\\x0453c\\x453N\"\n"
        #expect(WineRegistry.string(in: wine, key: #"Software\Uninstall"#, name: "DisplayName") == "RPGѓcѓN")
    }

    @Test func japaneseFontsGetAReplacementUnlessThePlayerChoseOne() throws {
        let temp = try TempFolder()
        let userReg = temp.url.appending(path: "user.reg")
        let mine = WineRegistry.setString(in: "WINE REGISTRY Version 2\n", key: WindowsFonts.replacementsKey,
                                          name: "MS Gothic", value: "Osaka")
        try mine.write(to: userReg, atomically: true, encoding: .utf8)

        try WindowsFonts.replaceJapaneseFonts(bottle: temp.url)

        let text = try String(contentsOf: userReg, encoding: .utf8)
        let key = WindowsFonts.replacementsKey
        #expect(WineRegistry.string(in: text, key: key, name: "ＭＳ Ｐゴシック") == "Arial Unicode MS")
        #expect(WineRegistry.string(in: text, key: key, name: "MS Gothic") == "Osaka")
        let modified = try userReg.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try WindowsFonts.replaceJapaneseFonts(bottle: temp.url)
        #expect(try userReg.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
    }
}

@Suite struct RGSSArchiveTests {
    static func next(_ key: UInt32) -> UInt32 { key &* 7 &+ 3 }

    static func encrypt(_ data: Data, key start: UInt32) -> [UInt8] {
        var key = start
        var bytes = [UInt8](data)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            for byte in 0..<min(4, bytes.count - index) {
                bytes[index + byte] ^= UInt8(truncatingIfNeeded: key >> (8 * byte))
            }
            key = next(key)
        }
        return bytes
    }

    static func word(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }

    /// An XP/VX archive (`Game.rgss2a`) holding `files` in order.
    static func version1(_ files: [(String, Data)]) -> Data {
        var out = Array("RGSSAD\0".utf8) + [1]
        var key: UInt32 = 0xDEAD_CAFE
        for (name, data) in files {
            let nameBytes = Array(name.utf8)
            out += word(UInt32(nameBytes.count) ^ key)
            key = next(key)
            for byte in nameBytes {
                out.append(byte ^ UInt8(truncatingIfNeeded: key))
                key = next(key)
            }
            out += word(UInt32(data.count) ^ key)
            key = next(key)
            out += encrypt(data, key: key)
        }
        return Data(out)
    }

    /// A VX Ace archive (`Game.rgss3a`).
    static func version3(_ files: [(String, Data)], seed: UInt32 = 0x1234) -> Data {
        let key = seed &* 9 &+ 3
        var table: [UInt8] = []
        var blobs: [UInt8] = []
        let tableSize = files.reduce(16) { $0 + 16 + $1.0.utf8.count }
        for (index, (name, data)) in files.enumerated() {
            let dataKey = UInt32(0xABC0 + index)
            let offset = UInt32(12 + tableSize + blobs.count)
            table += word(offset ^ key) + word(UInt32(data.count) ^ key) + word(dataKey ^ key)
            let nameBytes = Array(name.utf8)
            table += word(UInt32(nameBytes.count) ^ key)
            table += nameBytes.enumerated().map { $0.element ^ UInt8(truncatingIfNeeded: key >> (8 * ($0.offset % 4))) }
            blobs += encrypt(data, key: dataKey)
        }
        table += word(key) + word(0) + word(0) + word(0)
        return Data(Array("RGSSAD\0".utf8) + [3] + word(seed) + table + blobs)
    }

    /// A scripts file as RPG Maker writes it: each script's source zlib-compressed, between Ruby's own bytes.
    static func scripts(_ sources: [String]) throws -> Data {
        var out = Data([0x04, 0x08, 0x5B])
        for source in sources {
            out.append(contentsOf: [0x5B, 0x08, 0x69, 0x22])
            out.append(Data([0x78, 0x9C]) + (try (Data(source.utf8) as NSData).compressed(using: .zlib) as Data))
            out.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // zlib's checksum, not checked
        }
        return out
    }

    @Test func theScriptsComeOutOfBothKindsOfArchive() throws {
        let scripts = try Self.scripts(["class Scene_Title\nend", "Graphics.resize_screen(640, 480)"])
        let files = [("Graphics\\Titles\\Title.png", Data(repeating: 7, count: 13)), ("Data\\Scripts.rvdata", scripts)]
        let wanted = { (name: String) in name.hasSuffix("Scripts.rvdata") }
        #expect(RGSSArchive.file(in: Self.version1(files), where: wanted) == scripts)
        #expect(RGSSArchive.file(in: Self.version3(files), where: wanted) == scripts)
        #expect(RGSSArchive.file(in: Self.version1(files)) { $0 == "Missing" } == nil)
        #expect(RGSSArchive.file(in: Data("RGSSAD\0\u{1}garbage".utf8), where: wanted) == nil)
        #expect(RGSSArchive.source(of: scripts).contains("resize_screen(640, 480)"))
    }

    @Test func theGameSaysItsSizeInItsScripts() throws {
        func screen(_ engine: RPGMakerGame.Engine, _ sources: [String]?) throws -> GameScaling.Size? {
            RPGMakerGame.screen(engine: engine, scripts: try sources.map(Self.scripts))
        }
        let vga = GameScaling.Size(width: 640, height: 480)
        // "Let's Do The Goodfeeling Wife! RPG" (VX) asks for 640×480; VX and VX Ace draw 544×416 otherwise.
        #expect(try screen(.rgss2, ["Graphics.resize_screen(640, 480)"]) == vga)
        #expect(try screen(.rgss3, ["class Scene_Map\nend"]) == GameScaling.Size(width: 544, height: 416))
        // rumika: a full-screen script computes sizes too; the largest written size is the game's.
        #expect(try screen(.rgss3, ["Graphics.resize_screen(640, 480)", "resize_screen(base_w, base_h)"]) == vga)
        #expect(try screen(.rgss3, ["Graphics.resize_screen(@w, @h)"]) == nil)
        #expect(try screen(.rgss3, nil) == nil)
        // XP can't change its size.
        #expect(try screen(.rgss1, nil) == vga)
    }

    @Test func aFirstLaunchIsEnlargedLikeTheLaterOnes() throws {
        let temp = try TempFolder()
        try Data("WINE REGISTRY Version 2\n".utf8).write(to: temp.url.appending(path: "user.reg"))
        let game = GameRecord(id: .make(), name: "RPG", executable: "/g/Game.exe", folder: "/g", hasMarker: true,
                              addedAt: Date())
        let screen = GameScaling.Size(width: 1728, height: 1056)
        let predicted = GameScaling.LearnedWindow(width: 640, height: 480, fullScreen: false)
        #expect(try GameLauncher.configure(bottle: temp.url, for: game, retina: false, screen: screen) == 1)
        #expect(try GameLauncher.configure(bottle: temp.url, for: game, retina: false, screen: screen,
                                           predicted: predicted) == 2)
        var seen = game
        seen.window = GameScaling.LearnedWindow(width: 1280, height: 720, fullScreen: false)
        #expect(try GameLauncher.configure(bottle: temp.url, for: seen, retina: false, screen: screen,
                                           predicted: predicted) == 1)
    }
}
