import Foundation

/// A game made with RPG Maker XP, VX or VX Ace, read from the `Game.ini` next to its `Game.exe`.
///
/// Their `Game.exe` is only a loader: the engine (`RGSS200J.dll` and the like) and the shared graphics, music and
/// fonts come from the maker's Run Time Package, which players install once on Windows. Without it the loader
/// shows an empty error box and quits ("Let's Do The Goodfeeling Wife! RPG", VX, asked for `RGSS200J.dll`).
/// Plaviox installs the package the game names (`RTPInstaller`).
///
/// MV and MZ games are NW.js programs that carry everything themselves; 2000 and 2003 use `RPG_RT.ini` and a
/// different package, not handled yet.
public struct RPGMakerGame: Sendable, Equatable {
    /// The engine generation, as RGSS names its registry key: `HKLM\Software\Enterbrain\<engine>\RTP`.
    public enum Engine: String, Sendable, Codable, CaseIterable {
        /// RPG Maker XP: `RGSS1xx*.dll`.
        case rgss1 = "RGSS"
        /// RPG Maker VX: `RGSS2xx*.dll`.
        case rgss2 = "RGSS2"
        /// RPG Maker VX Ace: `RGSS3xx.dll`.
        case rgss3 = "RGSS3"

        /// The maker's name, for "Installing RPG Maker VX RTP".
        public var displayName: String {
            switch self {
            case .rgss1: "RPG Maker XP"
            case .rgss2: "RPG Maker VX"
            case .rgss3: "RPG Maker VX Ace"
            }
        }
    }

    public var engine: Engine
    /// The packages the game asks for by name (`RTP=RPGVX`; XP's `RTP1=Standard`, `RTP2`, `RTP3`). Empty for a
    /// game that carries everything itself (`RTP=` in many VX Ace games).
    public var rtps: [String]
    /// The size of the game's picture, known before it runs (`RGSSArchive`); nil when it can't be told.
    public var screen: GameScaling.Size?

    public static let iniName = "Game.ini"

    /// The game whose `Game.ini` sits in `folder`, or nil when there is none or it isn't an RGSS game.
    public static func read(folder: URL) -> RPGMakerGame? {
        guard let data = try? Data(contentsOf: folder.appending(path: iniName)),
              var game = parse(ini: data) else { return nil }
        game.screen = screen(engine: game.engine, scripts: RGSSArchive.scripts(inGameFolder: folder))
        return game
    }

    /// XP always draws 640×480. VX and VX Ace draw 544×416 unless a script asks for another size; a size only
    /// computed while the game runs makes it unknown.
    static func screen(engine: Engine, scripts: Data?) -> GameScaling.Size? {
        if engine == .rgss1 { return GameScaling.Size(width: 640, height: 480) }
        guard let scripts else { return nil }
        let source = RGSSArchive.source(of: scripts)
        guard !source.isEmpty else { return nil }
        if let resized = RGSSArchive.resizedScreen(in: source) { return resized }
        return source.contains("resize_screen") ? nil : GameScaling.Size(width: 544, height: 416)
    }

    /// The `[Game]` section's `Library` decides the engine; a `Game.ini` without one belongs to another engine
    /// (Wolf RPG Editor games have a `Game.ini` too, with window settings).
    public static func parse(ini data: Data) -> RPGMakerGame? {
        let values = IniFile.section("Game", in: IniFile.text(data))
        guard let library = values["library"], let engine = engine(library: library) else { return nil }
        let keys = engine == .rgss1 ? ["rtp1", "rtp2", "rtp3"] : ["rtp"]
        let rtps = keys.compactMap { values[$0] }.filter { !$0.isEmpty }
        return RPGMakerGame(engine: engine, rtps: rtps)
    }

    /// `RGSS103J.dll`, `System\RGSS301.dll` → the generation from the first digit after `RGSS`.
    static func engine(library: String) -> Engine? {
        let name = library.split(whereSeparator: { $0 == "\\" || $0 == "/" || $0 == "¥" }).last
            .map(String.init)?.uppercased() ?? ""
        guard name.hasPrefix("RGSS"), let digit = name.dropFirst(4).first else { return nil }
        switch digit {
        case "1": return .rgss1
        case "2": return .rgss2
        case "3": return .rgss3
        default: return nil
        }
    }
}

/// Windows `.ini` files as the old games write them: in the system's code page, not UTF-8.
enum IniFile {
    /// UTF-8 when the bytes are valid UTF-8, else Shift-JIS (the RPG Maker games Plaviox meets are Japanese),
    /// else the ASCII part alone: the keys are ASCII in every code page.
    static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS)
            ?? String(bytes: data.map { $0 < 0x80 ? $0 : UInt8(ascii: "?") }, encoding: .ascii) ?? ""
    }

    /// The values of one `[section]`, keyed by lowercased name, trimmed.
    static func section(_ name: String, in text: String) -> [String: String] {
        var values: [String: String] = [:]
        var inside = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inside = line.dropFirst().prefix { $0 != "]" }.caseInsensitiveCompare(name) == .orderedSame
                continue
            }
            guard inside, !line.hasPrefix(";"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            values[key] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        return values
    }
}
