import Foundation

extension GameLauncher {
    /// One of the things a game needs being installed: "Installing components this game needs (1 of 2)".
    public struct Component: Sendable, Equatable {
        /// "Microsoft Visual C++ 2010", "RPG Maker VX Ace RTP".
        public var name: String
        /// From 1.
        public var number: Int
        public var count: Int
        public var phase: RedistInstaller.Phase
    }

    /// Where a game's files go: its bottle, and the runtime that runs the installers.
    struct Target: Sendable {
        var bottle: URL
        var runtime: RuntimeManifest.Runtime
        var runtimeFolder: URL

        init(_ bottle: URL, _ runtime: RuntimeManifest.Runtime, _ runtimeFolder: URL) {
            self.bottle = bottle
            self.runtime = runtime
            self.runtimeFolder = runtimeFolder
        }
    }

    /// What a game needs beyond Windows itself, read from its folder: RPG Maker's packages, Microsoft's runtimes
    /// and its language.
    struct GameFiles: Sendable {
        var rtps: [(rtp: RuntimeManifest.RTP, folder: URL)] = []
        /// The runtimes the game needs and its bottle has, by manifest id.
        var redists: [String] = []
        /// What couldn't be installed, for the game's log.
        var notes: [String] = []
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
    /// Everything still to install is counted first, so the sheet can say "1 of 2" from the start.
    func gameFiles(for game: GameRecord, info: ExecutableInfo, in target: Target, fetch: Bool,
                   progress: @Sendable (Step) -> Void) async throws -> GameFiles {
        guard game.store == nil else { return GameFiles() }
        let exe = URL(filePath: game.executable)
        let folder = exe.deletingLastPathComponent()
        let rpgMaker = RPGMakerGame.read(folder: folder)
        let manifest = try? ManifestUpdater(paths: paths).current()
        let rtps = rpgMaker.map { game in game.rtps.compactMap { manifest?.rtp($0, engine: game.engine) } } ?? []
        let redists = RedistNeeds.read(executable: exe, info: info)
            .map { RedistNeeds.needed($0, from: manifest?.redists ?? []) } ?? []

        let rtpInstaller = RTPInstaller(paths: paths, host: host)
        let missingRTPs = fetch ? rtps.filter { rtpInstaller.installed($0) == nil } : []
        let missingRedists = fetch ? redists.filter {
            !RedistInstaller.isInstalled($0, in: target.bottle) && !RedistInstaller.failedBefore($0, in: target.bottle)
        } : []
        let count = missingRTPs.count + missingRedists.count

        var files = GameFiles(locale: GameLanguage.locale(forGameIn: folder))
        files.window = rpgMaker?.screen.map { GameScaling.LearnedWindow(width: $0.width, height: $0.height,
                                                                       fullScreen: false) }
        for rtp in rtps {
            if let installed = rtpInstaller.installed(rtp) {
                files.rtps.append((rtp, installed))
            } else if let index = missingRTPs.firstIndex(of: rtp) {
                let component = Component(name: "\(rpgMaker?.engine.displayName ?? "RPG Maker") RTP",
                                          number: index + 1, count: count, phase: .installing)
                // The installers report only until they return.
                let installed = try await withoutActuallyEscaping(progress) { progress in
                    try await rtpInstaller.install(rtp, runtime: target.runtime) {
                        progress(.component(component.at($0)))
                    }
                }
                files.rtps.append((rtp, installed))
            }
        }
        for redist in redists {
            if let index = missingRedists.firstIndex(of: redist) {
                let component = Component(name: redist.name, number: missingRTPs.count + index + 1, count: count,
                                          phase: .installing)
                files.notes += try await install(redist, for: game, in: target, as: component, progress: progress)
            }
            if RedistInstaller.isInstalled(redist, in: target.bottle) { files.redists.append(redist.id) }
        }
        return files
    }

    /// Installs one runtime; returns the lines for the game's log when it couldn't be.
    private func install(_ redist: RuntimeManifest.Redist, for game: GameRecord, in target: Target,
                         as component: Component, progress: @Sendable (Step) -> Void) async throws -> [String] {
        let result = try await withoutActuallyEscaping(progress) { progress in
            try await RedistInstaller(paths: paths, host: host).install(
                redist, into: target.bottle, runtimeFolder: target.runtimeFolder, windows: game.windowsVersion
            ) { progress(.component(component.at($0))) }
        }
        guard !result.installed else { return [] }
        return ["[EscApp] Couldn't install \(redist.id) (code \(result.status)):"]
            + result.output.split(separator: "\n").suffix(20).map { "    \($0)" }
    }
}

extension GameLauncher.Component {
    func at(_ phase: RedistInstaller.Phase) -> Self {
        var component = self
        component.phase = phase
        return component
    }
}
