import AppKit
import MagicKettleKit
import SwiftUI

/// Settings, as in the design (Settings.dc.html): a sidebar of sections, each showing its card — general,
/// components, disk space, saves. Stores have their own screen in the main window, not a section here.
/// Sections Magic Kettle has nothing for yet (about, auto-retry, the folder for new games) are left out.
struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case general, components, directX12, disk, saves
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .general: "General"
            case .components: "Components"
            case .directX12: "DirectX 12"
            case .disk: "Disk Space"
            case .saves: "Saves"
            }
        }
    }

    static let sectionKey = "SettingsSection"
    let components: ComponentsModel
    let library: LibraryModel
    /// Remembered, and set by "Check for Component Updates…" to land on Components.
    @AppStorage(SettingsView.sectionKey) private var section: Section = .general
    let directX12: DirectX12Model

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            // One section at a time: scrolling a page that already fit on screen looked like a dead sidebar.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(section.title)
                        .font(.system(size: 22, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    page
                        .frame(maxWidth: 640, alignment: .leading)
                }
                .padding(.horizontal, 24)
                // Level with the sidebar's first section, below the traffic lights.
                .padding(.top, 48)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(section)
        }
        .background(Color.windowBackground)
        // The design has no keyboard focus rings; macOS draws a blue one around the focused button.
        .focusEffectDisabled()
        .ignoresSafeArea(edges: .top)
        // The Settings scene sizes its window to the content's ideal size; the design's is 1200 × 780.
        .frame(minWidth: 960, idealWidth: 1200, minHeight: 600, idealHeight: 780)
        .background(WindowChrome(firstLight: CGPoint(x: 22, y: 22),
                                 frameKey: "NSWindow Frame com_apple_SwiftUI_Settings_window"))
        .onAppear {
            components.reload()
            components.measureDisk()
            library.reload()
        }
    }

    @ViewBuilder private var page: some View {
        switch section {
        case .general: GeneralCard(components: components, library: library)
        case .components: ComponentsCard(components: components)
        case .directX12: DirectX12Card(model: directX12, components: components)
        case .disk: DiskCard(components: components)
        case .saves: SavesCard(profile: components.paths.profile)
        }
    }

    /// 220 wide, #EFECE7, the traffic lights at the top, then the sections.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Room for the traffic lights: 16 top + 12 lights + 20 below.
            Color.clear.frame(height: 32)
            ForEach(Section.allCases) { item in
                Button { section = item } label: {
                    Text(item.title)
                        .font(.system(size: 14, weight: section == item ? .semibold : .regular))
                        .foregroundStyle(section == item ? Color.navSelectedText : .primary)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                        // `navSelected` almost vanishes on the sidebar's #EFECE7; a brand tint shows in both themes.
                        .background(section == item ? Color.brand.opacity(0.18) : .clear, in: .rect(cornerRadius: 8))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == item ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(Color.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.cardBorder).frame(width: 1) }
        .gesture(WindowDragGesture())
    }
}

/// A white card, 18/20 padding and 12-pt gaps; the page above it has the section's name.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .font(.system(size: 14))
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cardBorder) }
    }
}

struct Note: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Color.secondaryText)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ComponentsCard: View {
    let components: ComponentsModel
    @State private var showsLicenses = false

    var body: some View {
        SettingsCard {
            if let current = components.catalog?.current {
                ForEach(current.components, id: \.kind) { component in
                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            Text(component.kind.title)
                            Text(component.version).font(.system(size: 12)).foregroundStyle(Color.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        status(for: component)
                    }
                }
            } else {
                Text("Not installed yet").foregroundStyle(Color.secondaryText)
            }
            HStack(spacing: 12) {
                Text("Rosetta 2").frame(maxWidth: .infinity, alignment: .leading)
                if components.rosettaInstalled {
                    Text("Rosetta is installed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.okText)
                } else {
                    Text("Not installed").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.brand)
                }
            }
            actions
                .padding(.top, 4)
            if let progress = components.updating {
                VStack(alignment: .leading, spacing: 6) {
                    Note(text: "\(progress.label)")
                    ProgressView(value: progress.fraction).tint(.brand)
                }
            } else if let error = components.checkError ?? components.updateError {
                Note(text: "\(error)")
            }
        }
    }

    @ViewBuilder private func status(for component: RuntimeManifest.Component) -> some View {
        if case let .updateAvailable(_, newest)? = components.catalog?.status,
           let newer = newest.components.first(where: { $0.kind == component.kind }),
           newer.sha256 != component.sha256 {
            Text("\(newer.version) available")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.brand)
                .fixedSize()
        } else {
            Text("Latest").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.okText)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if components.catalog?.updateAvailable == true, components.updating == nil {
                Button("Update") { Task { await components.installUpdate() } }
                    .buttonStyle(CompactButtonStyle(kind: .primary))
            }
            Button(components.isChecking ? "Checking…" : "Check for Updates") {
                Task { await components.checkNow() }
            }
            .buttonStyle(CompactButtonStyle())
            .disabled(components.isChecking)
            Spacer(minLength: 0)
            Button("Licenses") { showsLicenses = true }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .fixedSize()
                .foregroundStyle(Color.brand)
                .popover(isPresented: $showsLicenses, arrowEdge: .bottom) { licenses }
        }
    }

    private var licenses: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(components.catalog?.current?.components ?? [], id: \.kind) { component in
                HStack {
                    Text("\(component.kind.title) \(component.version)").frame(maxWidth: .infinity, alignment: .leading)
                    Text(component.license).foregroundStyle(Color.secondaryText)
                }
            }
            // Downloaded only for games made with RPG Maker that need them (`RTPInstaller`).
            HStack {
                Text("RPG Maker Run Time Packages").frame(maxWidth: .infinity, alignment: .leading)
                Text("Enterbrain").foregroundStyle(Color.secondaryText)
            }
            // Installed only into the Windows of games built with them (`RedistInstaller`).
            HStack {
                Text("Microsoft Visual C++ and .NET").frame(maxWidth: .infinity, alignment: .leading)
                Text("Microsoft").foregroundStyle(Color.secondaryText)
            }
            HStack {
                Text("Rosetta 2").frame(maxWidth: .infinity, alignment: .leading)
                Text("Apple").foregroundStyle(Color.secondaryText)
            }
        }
        .font(.system(size: 13))
        .padding(16)
        .frame(width: 360)
    }
}

private struct DiskCard: View {
    let components: ComponentsModel

    var body: some View {
        SettingsCard {
            if let usage = components.diskUsage {
                Text(usage.total.formatted(.byteCount(style: .file)))
                    .font(.system(size: 26, weight: .bold))
                bar(usage)
                legend(color: .brand, title: "Wine and graphics", bytes: usage.runtimes)
                legend(color: .diskTemplate, title: "Clean Windows (template)", bytes: usage.templates)
                legend(color: .diskGames, title: "Windows for \(usage.bottleCount) games", bytes: usage.bottles)
                Note(text: """
                    Finder shows more: the games' Windows setups are copies of the template that share its space. \
                    Games and saves aren't counted here.
                    """)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func bar(_ usage: DiskUsage) -> some View {
        GeometryReader { geometry in
            let total = max(Double(usage.total), 1)
            HStack(spacing: 0) {
                Color.brand.frame(width: geometry.size.width * Double(usage.runtimes) / total)
                Color.diskTemplate.frame(width: geometry.size.width * Double(usage.templates) / total)
                Color.diskGames.frame(width: geometry.size.width * Double(usage.bottles) / total)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 12)
        .background(Color.track)
        .clipShape(.rect(cornerRadius: 6))
        .accessibilityHidden(true)
    }

    private func legend(color: Color, title: LocalizedStringKey, bytes: Int64) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            Text(bytes.formatted(.byteCount(style: .file)))
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
        }
    }
}

private struct SavesCard: View {
    let profile: URL

    var body: some View {
        SettingsCard {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shared by all games")
                    Text((profile.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryText)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Show") {
                    try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(profile)
                }
                .buttonStyle(CompactButtonStyle())
            }
            Note(text: "Games write AppData and Saved Games here. “My Documents” is your Documents folder.")
        }
    }
}

private struct GeneralCard: View {
    let components: ComponentsModel
    let library: LibraryModel
    @State private var language = AppLanguage.current
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system
    @State private var languageChanged = false

    var body: some View {
        @Bindable var components = components
        SettingsCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Language")
                    if languageChanged {
                        Text("Applies after Magic Kettle restarts")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DesignSelect(selection: $language, options: AppLanguage.allCases, title: \.title)
                    .onChange(of: language) {
                        language.apply()
                        languageChanged = true
                    }
            }
            HStack(spacing: 12) {
                Text("Appearance").frame(maxWidth: .infinity, alignment: .leading)
                DesignSelect(selection: $appearance, options: AppAppearance.allCases, title: \.title)
                    .onChange(of: appearance) { appearance.apply() }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open .exe files with a double-click")
                    Text("Magic Kettle is the default app for .exe and .msi")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // macOS has no "stop being the default"; another app takes over by being chosen in Finder.
                Toggle("", isOn: Binding(get: { library.isDefaultForExe },
                                         set: { if $0 { library.makeDefaultForExe() } }))
                    .toggleStyle(.switch)
                    .tint(.brand)
                    .labelsHidden()
                    .disabled(library.isDefaultForExe)
                    // Another app may have taken .exe since Magic Kettle started (chosen in Finder).
                    .onAppear { library.refreshDefaultHandler() }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sharp screen (Retina) for new games")
                    Text("""
                        Auto turns it on for games made for high-resolution screens. If clicks miss a game's \
                        buttons, set Retina to Off on that game's page.
                        """)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DesignSelect(selection: Binding(get: { library.newGameRetina }, set: { library.setNewGameRetina($0) }),
                             options: GameScaling.Setting.allCases, title: AdvancedPage.settingTitle)
            }
            ScreenAccessRow()
            HStack(spacing: 12) {
                Text("Update components automatically").frame(maxWidth: .infinity, alignment: .leading)
                Toggle("", isOn: $components.autoCheck)
                    .toggleStyle(.switch)
                    .tint(.brand)
                    .labelsHidden()
            }
        }
    }
}
