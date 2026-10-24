/// The environment a game process starts with. A pure function, so every launch can be checked in a test.
public enum WineEnvironment {
    /// The only host variables that reach Wine. Anything else from the user's shell (`DYLD_*`, a stray
    /// `WINEPREFIX`, proxy settings) could change how a game runs in ways nobody can reproduce.
    public static let hostAllowlist: Set<String> = [
        "HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", "LC_ALL", "SHELL",
    ]

    /// - Parameters:
    ///   - extra: per-game variables from Advanced settings. Applied last, so the user always wins.
    ///   - verboseLog: keeps Wine's default `fixme`/`err` output for the log instead of silencing it.
    ///   - fastSync: osync, Wine's events, mutexes and semaphores handled inside each process instead of by asking
    ///     wineserver every time (EscApp's Wine 11.20 build 3 onwards, `Wine.supportsFastSync`). The bottle's
    ///     wineserver decides, from the environment it starts with, and its processes follow it; so a bottle's
    ///     processes all take the setting from the same place, `fastSync(for:wine:)`.
    public static func make(
        host: [String: String],
        bottle: String,
        extra: [String: String] = [:],
        verboseLog: Bool = false,
        fastSync: Bool = false
    ) -> [String: String] {
        var env = host.filter { hostAllowlist.contains($0.key) }
        env["WINEPREFIX"] = bottle
        // Without fixme lines, so a long session doesn't write gigabytes of them, but with errors: they are what
        // `LogDiagnosis` reads to tell a missing game file from a graphics failure. The verbose log adds
        // exceptions and DLL loads, which is what diagnosing a crash at start needs. Both keep the text of the
        // game's message boxes: an old game asking for its CD says so in one, and nothing else in the log does.
        env["WINEDEBUG"] = verboseLog ? "+seh,+loaddll,+msgbox" : "fixme-all,trace+msgbox"
        env["WINEDLLOVERRIDES"] = dllOverrides
        if fastSync { env["WINEOSYNC"] = "1" }
        env.merge(extra) { _, user in user }
        return env
    }

    /// `winemenubuilder` is always off: it would add Start Menu shortcuts and file associations for every
    /// installer to the Mac (`~/Applications`, Launch Services), which EscApp manages itself. Graphics backends need
    /// no overrides: each runs from its own Wine tree (`BackendTree`).
    static let dllOverrides = "winemenubuilder.exe=d"

    /// The runtime feature that says a Wine build has osync.
    static let fastSyncFeature = "osync"

    /// osync for everything a bottle runs: on wherever the Wine has it, except for a game whose player turned
    /// it off in Advanced. A store's bottle is shared by its client and all its games, so it stays on there.
    public static func fastSync(for game: GameRecord?, wine: Wine) -> Bool {
        guard wine.supportsFastSync else { return false }
        guard let game, game.store == nil else { return true }
        return game.fastSync != false
    }

    /// Whether a running process's environment has osync on, the way Wine reads the variable: a number, on when
    /// it isn't zero.
    static func fastSyncIsOn(_ environment: [String: String]) -> Bool {
        (environment["WINEOSYNC"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0) != 0
    }
}
