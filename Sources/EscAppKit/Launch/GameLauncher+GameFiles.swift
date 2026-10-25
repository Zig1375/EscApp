import Foundation

extension GameLauncher {
    /// What a game needs beyond Windows itself, read from its folder: RPG Maker's packages and its language.
    struct GameFiles: Sendable {
        var rtps: [(rtp: RuntimeManifest.RTP, folder: URL)] = []
        /// `GameLanguage`; nil for the Mac's.
        var locale: String?
        /// The game's window as it will be, for a first launch to be enlarged like the later ones; nil when only
        /// running the game tells.
        var window: GameScaling.LearnedWindow?

        /// The packages linked into the game's bottle; the registry only while its Wine is down.
        func link(into bottle: URL, registry: Bool) throws {
            for (rtp, folder) in rtps {
                try RTPInstaller.link(folder, engine: rtp.engine, name: rtp.name, into: bottle, registry: registry)
            }
        }
    }

    /// A store's games are left alone: they come with what they need, and share their store's bottle.
    func gameFiles(for game: GameRecord, runtime: RuntimeManifest.Runtime, fetch: Bool,
                   progress: @Sendable (Step) -> Void) async throws -> GameFiles {
        guard game.store == nil else { return GameFiles() }
        let folder = URL(filePath: game.executable).deletingLastPathComponent()
        let rpgMaker = RPGMakerGame.read(folder: folder)
        let rtps = try await installRTPs(for: rpgMaker, runtime: runtime, fetch: fetch, progress: progress)
        let window = rpgMaker?.screen.map { GameScaling.LearnedWindow(width: $0.width, height: $0.height,
                                                                     fullScreen: false) }
        return GameFiles(rtps: rtps, locale: GameLanguage.locale(forGameIn: folder), window: window)
    }

    /// The RPG Maker packages the game names (`RPGMakerGame`), installed if they aren't yet. A package the
    /// manifest doesn't have (a maker's own `RTP2`) is left out: the game says what it misses itself.
    private func installRTPs(for game: RPGMakerGame?, runtime: RuntimeManifest.Runtime, fetch: Bool,
                             progress: @Sendable (Step) -> Void) async throws -> [(RuntimeManifest.RTP, URL)] {
        guard let game, !game.rtps.isEmpty, let manifest = try? ManifestUpdater(paths: paths).current() else {
            return []
        }
        let installer = RTPInstaller(paths: paths, host: host)
        var result: [(RuntimeManifest.RTP, URL)] = []
        for name in game.rtps {
            guard let rtp = manifest.rtp(name, engine: game.engine) else { continue }
            if let folder = installer.installed(rtp) {
                result.append((rtp, folder))
            } else if fetch {
                // The download reports only until `install` returns.
                let folder = try await withoutActuallyEscaping(progress) { progress in
                    try await installer.install(rtp, runtime: runtime) {
                        progress(.gameFiles(received: $0, total: $1))
                    }
                }
                result.append((rtp, folder))
            }
        }
        return result
    }
}
