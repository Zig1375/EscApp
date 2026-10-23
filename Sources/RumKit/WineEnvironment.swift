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
        backend: GraphicsBackend,
        extra: [String: String] = [:],
        verboseLog: Bool = false
    ) -> [String: String] {
        var env = host.filter { hostAllowlist.contains($0.key) }
        env["WINEPREFIX"] = bottle
        // Silent by default so a long session doesn't write gigabytes of fixme lines. The verbose log adds
        // exceptions and DLL loads, which is what diagnosing a crash at start needs.
        env["WINEDEBUG"] = verboseLog ? "+seh,+loaddll" : "-all"
        if let overrides = dllOverrides(for: backend) {
            env["WINEDLLOVERRIDES"] = overrides
        }
        env.merge(extra) { _, user in user }
        return env
    }

    /// `d3d11,dxgi=n,b`: load the backend's copy first, fall back to Wine's builtin if it's missing.
    static func dllOverrides(for backend: GraphicsBackend) -> String? {
        let dlls = backend.nativeDLLs
        guard !dlls.isEmpty else { return nil }
        return dlls.sorted().joined(separator: ",") + "=n,b"
    }
}
