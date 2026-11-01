import AppKit
import Foundation
import PlavioxKit
import UniformTypeIdentifiers

extension LibraryModel {
    /// The install sheet (Installer.dc.html): the disc's contents, where to install, then which program is the game.
    struct Install: Identifiable {
        enum Phase {
            /// A disc image is open; its installer hasn't run.
            case disc
            /// Choosing the game's folder.
            case folder
            case installing(GameInstaller.Step)
            case done(GameInstaller.Installed)
            case failed(log: URL?)
        }

        let id = UUID()
        var phase: Phase
        /// The disc in drive D:, when installing from an image.
        var disc: MountedDisc?
        var contents: DiscContents?
        var installer: URL?
        var kind: InstallerKind?
        var name = ""
        var folder: URL
        var keepDisc = true
        /// The program picked in the last step.
        var program: URL?

        /// The step numbers of the design, which counts the disc step only when there is a disc.
        func number(of phase: Phase) -> Int {
            let first = disc == nil ? 0 : 1
            switch phase {
            case .disc: return 1
            case .folder, .installing: return first + 1
            case .done, .failed: return first + 2
            }
        }

        /// The folder as Windows inside the bottle sees it, for installers that ask where to install.
        var windowsFolder: String {
            WindowsPath.windowsPath(of: folder, under: folder.deletingLastPathComponent(),
                                    drive: GameInstaller.gamesDrive) ?? #"G:\"#
        }
    }

    /// "Open Game…": an exe, an installer or a disc image.
    func chooseGameFile() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose the game's .exe, its installer or its disc image")
        panel.allowedContentTypes = [UTType("com.microsoft.windows-executable"), UTType(filenameExtension: "msi")]
            .compactMap { $0 } + DiscImage.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// Opening a disc image: it goes into drive D: and its contents show.
    func openDisc(_ image: URL) {
        guard install == nil else { return busyInstalling() }
        Task {
            do {
                let disc = try await DiscImage.attach(image, paths: paths)
                install = Install(phase: .disc, disc: disc, contents: DiscContents.read(disc.mountPoint),
                                  folder: paths.games)
            } catch {
                notice = Notice(title: String(localized: "Plaviox can't open this file"),
                                message: String(describing: error))
            }
        }
    }

    /// Opening an installer goes straight to choosing the folder: installers never show in the library.
    func openInstaller(_ url: URL, kind: InstallerKind, disc: MountedDisc? = nil) {
        guard install == nil || disc != nil else { return busyInstalling() }
        let name = GameInstaller.suggestedName(installer: url, disc: disc?.image)
        var next = install ?? Install(phase: .folder, folder: paths.games)
        next.phase = .folder
        next.installer = url
        next.kind = kind
        next.name = name
        next.folder = GameInstaller(paths: paths).defaultFolder(for: name)
        install = next
    }

    /// "Install Game" on the disc step.
    func installFromDisc() {
        guard let install, let installer = install.contents?.installer, let kind = installer.installer else { return }
        openInstaller(installer.url, kind: kind, disc: install.disc)
    }

    func chooseInstallFolder() {
        guard let current = install else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = current.folder.deletingLastPathComponent()
        panel.message = String(localized: "Choose the folder for \(current.name)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        install?.folder = url
    }

    func startInstall() {
        guard let current = install, let installer = current.installer, let kind = current.kind else { return }
        let plan = GameInstaller.Plan(installer: installer, kind: kind, name: current.name, folder: current.folder,
                                      disc: current.disc)
        install?.phase = .installing(.installing)
        Task {
            do {
                guard let (runtime, _) = try currentRuntime() else { throw BottleError.runtimeMissing("") }
                let installed = try await GameInstaller(paths: paths).install(plan, runtime: runtime) { step in
                    Task { @MainActor in
                        if case .installing? = self.install?.phase { self.install?.phase = .installing(step) }
                    }
                }
                if installed.found.programs.isEmpty {
                    GameInstaller(paths: paths).cancel(installed.id)
                    install?.phase = .failed(log: installed.log)
                } else {
                    install?.program = installed.found.recommended?.url ?? installed.found.programs.first?.url
                    install?.phase = .done(installed)
                }
            } catch {
                notice = Notice(title: String(localized: "Couldn't install \(plan.name)"),
                                message: String(describing: error))
                await closeInstall()
            }
        }
    }

    /// "Play" on the last step: the game joins the library with the program picked, and starts.
    func finishInstall() {
        guard let current = install, case let .done(installed) = current.phase, let program = current.program else {
            return
        }
        do {
            let record = try GameInstaller(paths: paths).finish(installed, program: program,
                                                                keepDisc: current.disc != nil && current.keepDisc)
            Task {
                // Out of the drive for now: a launch puts it back when the game needs it.
                await closeInstall()
                reload()
                play(record)
            }
        } catch {
            notice = Notice(title: String(localized: "Couldn't install \(current.name)"),
                            message: String(describing: error))
        }
    }

    func showInstalledFolder() {
        guard let current = install, let program = current.program else { return }
        NSWorkspace.shared.activateFileViewerSelecting([program])
    }

    /// "Eject Disc", "Cancel", or closing after a failed install. An install that finished but wasn't added
    /// takes its bottle along; the files it put in the game folder stay.
    func cancelInstall() {
        if case let .done(installed)? = install?.phase { GameInstaller(paths: paths).cancel(installed.id) }
        Task { await closeInstall() }
    }

    private func closeInstall() async {
        let disc = install?.disc
        install = nil
        if let disc { await DiscImage.detach(disc) }
    }

    private func busyInstalling() {
        notice = Notice(title: String(localized: "Another game is being installed"),
                        message: String(localized: "Finish installing it first, then open this file again."))
    }
}
