import Foundation

/// The fonts a Windows game expects to find as files in `C:\Windows\Fonts`.
///
/// Wine draws text with the Mac's fonts, but its bottles have no font files of their own, and a game that reads
/// the files itself finds nothing: Unity's UI text (FallenFlower's "Are you over 18?" dialog and every menu
/// button) looks up Arial there and drew empty boxes. macOS ships the Windows core fonts under their own names,
/// so each bottle gets links to them; nothing is copied and nothing is downloaded.
///
/// Plaviox's links are the ones that point into `macFolder`: that is what tells them from a font a game or its
/// installer put there, which is never replaced or removed.
public enum WindowsFonts {
    public static let macFolder = URL(filePath: "/System/Library/Fonts/Supplemental", directoryHint: .isDirectory)

    /// Families Windows has and macOS ships. Arial Unicode is also what gives Japanese and Chinese text glyphs
    /// when a game asks for Arial and falls back.
    static let families = [
        "Arial", "Comic Sans MS", "Courier New", "Georgia", "Impact", "Microsoft Sans Serif", "Tahoma",
        "Times New Roman", "Trebuchet MS", "Verdana", "Webdings", "Wingdings",
    ]

    /// The Mac font files that belong to those families ("Arial Bold.ttf", "Wingdings 2.ttf").
    static func chosen(from names: [String]) -> [String] {
        names.filter { name in
            guard name.lowercased().hasSuffix(".ttf") else { return false }
            let base = String(name.dropLast(4))
            return families.contains { base == $0 || base.hasPrefix($0 + " ") }
        }.sorted()
    }

    /// Links the fonts into the bottle's `Fonts` folder, and drops Plaviox's links to fonts macOS no longer has.
    /// Cheap enough to run on every launch, which is how bottles made before this existed get them too.
    public static func link(bottle: URL, macFonts: URL = macFolder) throws {
        let fileManager = FileManager.default
        let windows = bottle.appending(path: "drive_c/windows", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: windows.path) else { return }
        let fonts = windows.appending(path: "Fonts", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: fonts, withIntermediateDirectories: true)

        let wanted = Set(chosen(from: (try? fileManager.contentsOfDirectory(atPath: macFonts.path)) ?? []))
        for name in try fileManager.contentsOfDirectory(atPath: fonts.path) where !wanted.contains(name) {
            let item = fonts.appending(path: name)
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: item.path),
                  isOurs(destination, macFonts: macFonts),
                  !fileManager.fileExists(atPath: destination) else { continue }
            try fileManager.removeItem(at: item)
        }
        for name in wanted.sorted() {
            let item = fonts.appending(path: name)
            let source = macFonts.appending(path: name)
            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: item.path) {
                guard destination != source.path, isOurs(destination, macFonts: macFonts) else { continue }
                try fileManager.removeItem(at: item)
            } else if fileManager.fileExists(atPath: item.path) {
                continue
            }
            try fileManager.createSymbolicLink(atPath: item.path, withDestinationPath: source.path)
        }
    }

    /// Japanese Windows' fonts, which old Japanese games ask for by name, and the family drawn instead.
    ///
    /// RPG Maker XP writes its menus in `ＭＳ Ｐゴシック` and reads the font file itself (`GetFontData`): without
    /// it the title menu of RJ080230 had no text at all, and Hiragino, which Wine finds on the Mac, gave none
    /// either (OpenType collections, which that reader doesn't take). Arial Unicode is a plain TrueType file with
    /// the Japanese glyphs, linked into every bottle above.
    static let japaneseReplacement = "Arial Unicode MS"
    static let japaneseFonts = [
        "ＭＳ Ｐゴシック", "ＭＳ ゴシック", "ＭＳ Ｐ明朝", "ＭＳ 明朝", "MS PGothic", "MS Gothic", "MS PMincho", "MS Mincho",
        "MS UI Gothic",
    ]
    static let replacementsKey = #"Software\Wine\Fonts\Replacements"#

    /// Points the Japanese font names at `japaneseReplacement`, leaving any the player set otherwise. Writes
    /// `user.reg`, so only while the bottle's Wine is down (`WineRegistry`).
    static func replaceJapaneseFonts(bottle: URL) throws {
        let userReg = bottle.appending(path: "user.reg")
        let original = try String(contentsOf: userReg, encoding: .utf8)
        var text = original
        for name in japaneseFonts where WineRegistry.string(in: text, key: replacementsKey, name: name) == nil {
            text = WineRegistry.setString(in: text, key: replacementsKey, name: name, value: japaneseReplacement)
        }
        if text != original { try text.write(to: userReg, atomically: true, encoding: .utf8) }
    }

    private static func isOurs(_ destination: String, macFonts: URL) -> Bool {
        destination.hasPrefix(macFonts.path + "/")
    }
}
