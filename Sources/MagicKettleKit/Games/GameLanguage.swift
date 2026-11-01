import Foundation

/// Whether a game is Japanese, so it starts with Japanese as Windows' language for programs that aren't Unicode.
///
/// Old Japanese games keep their text in Shift-JIS and read it with the system's code page. On a Mac in Russian,
/// Wine's code page is 1251: "Let's Do The Goodfeeling Wife! RPG" showed its title as `‹СЂќ‚ї‚ў…` and its error
/// box empty. Japanese players' PCs run code page 932, which the game gets with `LC_ALL=ja_JP.UTF-8`.
public enum GameLanguage {
    /// What Wine reads to pick code page 932 and the Japanese locale.
    public static let japaneseLocale = "ja_JP.UTF-8"

    /// The locale the game in `folder` should start with; nil for the Mac's own.
    public static func locale(forGameIn folder: URL) -> String? {
        let fileManager = FileManager.default
        let top = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        var names = top
        for name in top {
            var isFolder: ObjCBool = false
            let path = folder.appending(path: name).path
            guard fileManager.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else { continue }
            names += (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
        }
        let inis = top.filter { $0.lowercased().hasSuffix(".ini") }
            .compactMap { try? Data(contentsOf: folder.appending(path: $0)) }
        return isJapanese(iniFiles: inis, fileNames: names) ? japaneseLocale : nil
    }

    /// Japanese when the game's `.ini` files have kana in them, or, when they are plain ASCII, when its file
    /// names do (`はじめにお読みください。.txt`, audio named in Japanese: an ANSI program opens those only with
    /// code page 932).
    ///
    /// An `.ini` written in another code page outweighs Japanese file names: a fan translation into Russian keeps
    /// the original's file names but its title is in code page 1251, and Japanese would garble that.
    /// Only full-width kana count: kanji alone could be Chinese, and the half-width katakana block is where code
    /// page 1251's Cyrillic letters land when read as Shift-JIS.
    static func isJapanese(iniFiles: [Data], fileNames: [String]) -> Bool {
        var otherCodePage = false
        for data in iniFiles where data.contains(where: { $0 >= 0x80 }) {
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS)
            if let text, hasKana(text) { return true }
            otherCodePage = true
        }
        return !otherCodePage && fileNames.contains(where: hasKana)
    }

    /// Hiragana or full-width katakana, U+3041–U+30FA: the `・` and `ー` marks right after them occur in Chinese
    /// text too.
    static func hasKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3041...0x30FA).contains($0.value) }
    }
}
