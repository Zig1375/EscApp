import Foundation

extension AutoLaunch {
    /// Looks at the game's window while it plays, for `timing.lateWatch`: true once a window it shows has stayed
    /// blank (`LateBlank`) and the program is Chromium (`chromium`, or a Chromium GPU process in the bottle by
    /// then: a launcher starts it later). False when everything in the bottle ends first, or time is up. The
    /// started program itself may quit early: Steam's bootstrapper restarts Steam.
    /// - Parameter switched: Chromium's switches are on: a GPU process then means they didn't reach Chromium (a
    ///   launcher that doesn't pass them on), and starting again wouldn't help.
    func lateBlank(_ running: any GameAttempt, patience: TimeInterval, chromium: Bool,
                   switched: Bool) async -> Bool {
        var late = LateBlank(patience: patience)
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
                if elapsed - (gpuSince ?? elapsed) >= patience / 2 { return true }
            } else {
                gpuSince = nil
            }
            if let look = await looks.look(at: windows(running.session), elapsed: elapsed),
               late.observe(look, at: elapsed), chromium || gpuProcess(running.session) {
                return true
            }
            guard (try? await Task.sleep(for: .seconds(timing.lateEvery))) != nil else { return false }
        }
        return false
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
