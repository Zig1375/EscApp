import Foundation

extension AutoLaunch {
    /// Chromium known only once its GPU process ran: a packed exe hides the files that tell ("Wife Tsuma Uninhabited
    /// Island", NW.js inside Enigma Virtual Box, settled on DXVK). Turns its switches on; Chromium's own order of
    /// backends follows (`order(afterFindingChromiumIn:tried:)`).
    static func foundChromium(_ ran: Ran, in game: inout GameRecord, context: Context) -> Bool {
        guard ran.attempt.failure == .blankPicture, context.control.retrying, game.chromium == nil,
              !context.chromiumProgram else { return false }
        game.chromium = .inProcessGPU
        return true
    }

    /// The Chromium drawing to try after `current` (nil: none was asked for).
    static func nextChromium(after current: ChromiumApp.Mode?) -> ChromiumApp.Mode? {
        current.map(\.next) ?? .inProcessGPU
    }

    /// A Chromium window that stayed blank: the same graphics again, with Chromium drawing another way, until
    /// one draws or no way is left. Returns those runs.
    func redrawn(_ ran: Ran, with backend: GraphicsBackend, of game: inout GameRecord,
                 at position: (number: Int, total: Int), context: Context) async throws -> [Ran] {
        var runs: [Ran] = []
        var last = ran
        while last.attempt.failure == .blankPicture, context.control.retrying,
              let mode = Self.nextChromium(after: game.chromium ?? (context.chromiumProgram ? .inProcessGPU : nil)) {
            game.chromium = mode
            context.events(.retrying(last.attempt, next: backend, attempt: position.number, total: position.total))
            last = try await attempt(backend, of: game, number: position.number, of: position.total, context: context)
            runs.append(last)
        }
        return runs
    }
}
