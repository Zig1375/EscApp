import EscAppKit
import SwiftUI

/// Installer.dc.html: the disc that was opened, where to install, and which program starts the installed game.
struct InstallSheet: View {
    let install: LibraryModel.Install
    let library: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch install.phase {
            case .disc: discStep
            case .folder: folderStep
            case let .installing(step): installingStep(step)
            case let .done(installed): doneStep(installed)
            case let .failed(log): failedStep(log)
            }
        }
        .padding(22)
        .frame(width: 400, alignment: .leading)
        .background(Color.cardBackground)
        .focusEffectDisabled()
        // The installed game only joins the library through "Play"; Escape mustn't throw the install away.
        .interactiveDismissDisabled()
    }

    // MARK: 1. Disc image open

    @ViewBuilder private var discStep: some View {
        StepTitle(number: install.number(of: .disc), title: "Disc image open")
        if let disc = install.disc {
            Text("""
                \(disc.image.lastPathComponent) (\(Self.size(of: disc.image))) is in drive **D:**, like a real CD \
                in a drive.
                """)
                .modifier(BodyStyle())
        }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(install.contents?.programs ?? [], id: \.url) { program in
                FileRow(icon: program.installer != nil ? "arrow.down.to.line" : "doc",
                        iconColor: program.installer != nil ? .brand : .secondaryText, name: program.name) {
                    if program.installer != nil {
                        Tag(text: "Installer", background: .installerTag, foreground: .installerTagText)
                    } else if program.isMenu {
                        Tag(text: "Disc menu", background: .chip, foreground: .bodyText)
                    }
                }
            }
            if let folders = install.contents?.folders, !folders.isEmpty {
                FileRow(icon: "folder", iconColor: .secondaryText, name: folders.joined(separator: ", ")) {}
            }
        }
        if install.contents?.installer == nil {
            Text("There's no installer on this disc.").modifier(HintStyle())
        }
        buttons {
            Button("Eject Disc") { library.cancelInstall() }
                .keyboardShortcut(.cancelAction)
            Button("Install Game") { library.installFromDisc() }
                .buttonStyle(BrandButtonStyle(kind: .primary, height: 32, radius: 8))
                .keyboardShortcut(.defaultAction)
                .disabled(install.contents?.installer == nil)
        }
    }

    // MARK: 2. Where to install

    @ViewBuilder private var folderStep: some View {
        StepTitle(number: install.number(of: .folder), title: "Where to install")
        VStack(alignment: .leading, spacing: 6) {
            Text("Game folder").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(Color.secondaryText)
                Text(verbatim: Self.tilde(install.folder))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Change…") { library.chooseInstallFolder() }
                    .buttonStyle(BrandButtonStyle(small: true))
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.fieldBackground, in: .rect(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.buttonBorder) }
            Text("The game goes into an ordinary folder on your Mac and stays there if its Windows is reset")
                .modifier(HintStyle())
        }
        if install.disc != nil {
            Toggle(isOn: Binding(get: { install.keepDisc }, set: { library.install?.keepDisc = $0 })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep the disc in after installing").font(.system(size: 13))
                    Text("The game checks for its CD on every launch").modifier(HintStyle())
                }
            }
            .toggleStyle(.checkbox)
            .tint(.brand)
        }
        if install.kind?.takesFolder == true {
            Text("Next, the game's installer opens, as in Windows. The folder is already filled in.")
                .modifier(HintStyle())
        } else {
            Text("""
                Next, the game's installer opens, as in Windows. If it asks where to install, enter \
                \(install.windowsFolder): that's this folder.
                """)
                .modifier(HintStyle())
        }
        buttons {
            Button("Cancel") { library.cancelInstall() }
                .keyboardShortcut(.cancelAction)
            Button("Install") { library.startInstall() }
                .buttonStyle(BrandButtonStyle(kind: .primary, height: 32, radius: 8))
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Installing

    @ViewBuilder private func installingStep(_ step: GameInstaller.Step) -> some View {
        StepTitle(number: install.number(of: .folder), title: "Installing \(install.name)")
        switch step {
        case let .windows(firstTime):
            Text(firstTime ? "Preparing Windows for the game (once, about 30 s)…" : "Preparing Windows for the game…")
                .modifier(BodyStyle())
        case .installing:
            Text("The installer's window is open. Go through it as in Windows: EscApp waits until it finishes.")
                .modifier(BodyStyle())
        case .findingGame:
            Text("Looking for the game's program…").modifier(BodyStyle())
        }
        ProgressView().progressViewStyle(.linear).tint(.brand)
    }

    // MARK: 3. Installed

    @ViewBuilder private func doneStep(_ installed: GameInstaller.Installed) -> some View {
        StepTitle(number: install.number(of: .done(installed)), title: "\(install.name) is installed", done: true)
        let programs = installed.found.programs
        if programs.count > 1 {
            Text("There are several programs in the folder. Which one starts the game?").modifier(BodyStyle())
        } else if let only = programs.first {
            Text("The game starts with \(only.name).").modifier(BodyStyle())
        }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(programs, id: \.url) { program in
                ProgramRow(program: program, selected: install.program == program.url) {
                    library.install?.program = program.url
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The game's main program")
        if let uninstaller = installed.found.uninstaller {
            Text("EscApp doesn't show the game's uninstaller (\(uninstaller))").modifier(HintStyle())
        }
        buttons {
            Button("Show in Finder") { library.showInstalledFolder() }
            Button("Play") { library.finishInstall() }
                .buttonStyle(BrandButtonStyle(kind: .primary, height: 32, radius: 8))
                .keyboardShortcut(.defaultAction)
                .disabled(install.program == nil)
        }
    }

    @ViewBuilder private func failedStep(_ log: URL?) -> some View {
        StepTitle(number: install.number(of: .failed(log: log)), title: "Nothing was installed")
        Text("The installer finished without putting a game program in the folder or in its Windows.")
            .modifier(BodyStyle())
        buttons {
            if let log { Button("Open Log") { library.openLog(log) } }
            Button("Close") { library.cancelInstall() }
                .buttonStyle(BrandButtonStyle(kind: .primary, height: 32, radius: 8))
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Parts

    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Spacer()
            content()
        }
        .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
        .padding(.top, 8)
    }

    static func size(of file: URL) -> String {
        let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// `~/Games/Fallout 2`, as the design writes it.
    static func tilde(_ url: URL) -> String {
        let path = url.standardized.path(percentEncoded: false)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardized.path(percentEncoded: false)
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard trimmed.hasPrefix(home) else { return trimmed }
        return "~/" + trimmed.dropFirst(home.count).drop { $0 == "/" }
    }
}

extension View {
    /// Shows the install sheet while `library` installs a game.
    func installSheet(_ library: LibraryModel) -> some View {
        sheet(item: Binding(get: { library.install }, set: { if $0 == nil { library.cancelInstall() } })) { install in
            InstallSheet(install: install, library: library)
        }
    }
}

/// The numbered circle and the step's title; the last step's number is green.
private struct StepTitle: View {
    let number: Int
    let title: LocalizedStringKey
    var done = false

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(done ? Color.stepDone : Color.brand, in: .circle)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .accessibilityAddTraits(.isHeader)
        }
    }
}

private struct FileRow<Trailing: View>: View {
    let icon: String
    let iconColor: Color
    let name: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(verbatim: name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.rowDivider) }
    }
}

private struct ProgramRow: View {
    let program: InstalledPrograms.Program
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Color.brand : Color.buttonBorder)
                Text(verbatim: program.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if program.recommended {
                    Tag(text: "Recommended", background: .newBackground, foreground: .newText)
                } else if program.role == .settings {
                    Tag(text: "Settings", background: .chip, foreground: .bodyText)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .contentShape(.rect)
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.rowDivider) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct Tag: View {
    let text: LocalizedStringKey
    let background: Color
    let foreground: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
            .background(background, in: .capsule)
    }
}

private struct BodyStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13))
            .lineSpacing(4)
            .foregroundStyle(Color.bodyText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HintStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12))
            .foregroundStyle(Color.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
