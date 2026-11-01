import Foundation

extension AutoLaunch {
    /// Looks at the game's window while it plays, for `timing.lateWatch`: `blankPicture` once a window it shows
    /// has stayed blank (`LateBlank`) and the program is Chromium (`chromium`, or a Chromium GPU process in the
    /// bottle by then: a launcher starts it later); `frozen` once any game hangs on a blank window
    /// (`FrozenWindow`). Nil when everything in the bottle ends first, or time is up. The started program itself
    /// may quit early: Steam's bootstrapper restarts Steam.
    /// - Parameter switched: Chromium's switches are on: a GPU process then means they didn't reach Chromium (a
    ///   launcher that doesn't pass them on), and starting again wouldn't help.
    func lateFailure(_ running: any GameAttempt, patience: TimeInterval, chromium: Bool,
                     switched: Bool) async -> AttemptJudge.Failure? {
        var late = LateBlank(patience: patience)
        var frozen = FrozenWindow(holds: timing.frozenFor)
        var looks = PictureLooks(picture: picture, every: timing.lateEvery)
        let start = Date()
        var gpuSince: TimeInterval?
        while Date().timeIntervalSince(start) < timing.lateWatch, !running.isIdle {
            if running.exitCode != nil { running.watchForIdle() }
            let elapsed = Date().timeIntervalSince(start)
            // Started later by a launcher: a Chromium GPU process that keeps running (not one that fails and
            // quits, as Epic's does) means a blank window.
            if !switched, gpuProcess(running.session) {
                gpuSince = gpuSince ?? elapsed
                if elapsed - (gpuSince ?? elapsed) >= patience / 2 { return .blankPicture }
            } else {
                gpuSince = nil
            }
            let owners = windows(running.session)
            let look = await looks.look(at: owners, elapsed: elapsed)
            if let look, late.observe(look, at: elapsed), chromium || gpuProcess(running.session) {
                return .blankPicture
            }
            if !owners.isEmpty,
               frozen.observe(blank: look?.nearlyBlank ?? fullScreen(owners), cpu: cpu(owners), owners: owners,
                              at: elapsed) {
                return .frozen
            }
            guard (try? await Task.sleep(for: .seconds(timing.lateEvery))) != nil else { return nil }
        }
        return nil
    }
}

/// Looks at a Chromium program's window about once a second while it is up (`WindowPicture`).
struct PictureLooks {
    let picture: @Sendable ([Int32]) async -> WindowLook?
    let every: TimeInterval
    private var last: TimeInterval = -.infinity

    init(picture: @escaping @Sendable ([Int32]) async -> WindowLook?, every: TimeInterval) {
        self.picture = picture
        self.every = every
    }

    /// What the window shows now; nil between looks, without a window, or when it can't be told.
    mutating func look(at owners: [Int32], elapsed: TimeInterval) async -> WindowLook? {
        guard !owners.isEmpty, elapsed - last >= every else { return nil }
        last = elapsed
        return await picture(owners)
    }

    /// A Chromium GPU process in the game's bottle: Chromium after all, unpacked or started by a launcher.
    static func chromiumRuns(for session: GameSession) -> Bool {
        guard let bottle = session.environment["WINEPREFIX"] else { return false }
        return ChromiumApp.runsGPUProcess(in: URL(filePath: bottle, directoryHint: .isDirectory))
    }
}

/// The looks at the window while an attempt is checked: whether it is blank, for a Chromium program, and whether
/// the game froze (`AttemptJudge.checksFrozen`).
struct WatchLooks {
    var looks: PictureLooks
    var frozen: FrozenWindow
    /// Whether these processes' window fills its screen (`GameWindows.fillsScreen`).
    let fullScreen: ([Int32]) -> Bool
    private var lastLook: TimeInterval = -.infinity
    private var now: TimeInterval = 0

    init(looks: PictureLooks, frozen: FrozenWindow, fullScreen: @escaping ([Int32]) -> Bool) {
        self.looks = looks
        self.frozen = frozen
        self.fullScreen = fullScreen
    }

    /// A game that looks frozen so far doesn't make the attempt work yet: a freeze hides under the cover only if
    /// it is caught before the game is shown. It works once it draws or uses the CPU again; a freeze fails it.
    func accepts(_ verdict: AttemptJudge.Verdict) -> Bool {
        verdict != .working || !frozen.suspected(at: now)
    }

    mutating func look(at owners: [Int32], elapsed: TimeInterval, judge: AttemptJudge,
                       cpu: ([Int32]) -> TimeInterval?) async -> (blank: Bool?, frozen: Bool) {
        now = elapsed
        guard judge.checksPicture || judge.checksFrozen, !owners.isEmpty,
              elapsed - lastLook >= looks.every else { return (nil, false) }
        lastLook = elapsed
        let look = await looks.look(at: owners, elapsed: elapsed)
        // Without the Screen Recording permission the picture can't be seen, and nothing asks for it: a window
        // filling the screen stands in for a blank one. Among Us's frozen window did, while idle.
        let isFrozen = judge.checksFrozen
            && frozen.observe(blank: look?.nearlyBlank ?? fullScreen(owners), cpu: cpu(owners), owners: owners,
                              at: elapsed)
        return (judge.checksPicture ? look?.blank : nil, isFrozen)
    }
}
