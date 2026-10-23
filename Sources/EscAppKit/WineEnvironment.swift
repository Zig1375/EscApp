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
    public static func make(
        host: [String: String],
        bottle: String,
        extra: [String: String] = [:],
        verboseLog: Bool = false
    ) -> [String: String] {
        var env = host.filter { hostAllowlist.contains($0.key) }
        env["WINEPREFIX"] = bottle
        // Without fixme lines, so a long session doesn't write gigabytes of them, but with errors: they are what
        // `LogDiagnosis` reads to tell a missing game file from a graphics failure. The verbose log adds
        // exceptions and DLL loads, which is what diagnosing a crash at start needs.
        env["WINEDEBUG"] = verboseLog ? "+seh,+loaddll" : "fixme-all"
        env["WINEDLLOVERRIDES"] = dllOverrides
        env.merge(extra) { _, user in user }
        return env
    }

    /// `winemenubuilder` is always off: it would add Start Menu shortcuts and file associations for every
    /// installer to the Mac (`~/Applications`, Launch Services), which EscApp manages itself. Graphics backends need
    /// no overrides: each runs from its own Wine tree (`BackendTree`).
    static let dllOverrides = "winemenubuilder.exe=d"
}
