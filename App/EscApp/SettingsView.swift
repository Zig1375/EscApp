import AppKit
import EscAppKit
import SwiftUI

/// Settings, as in the design (Settings.dc.html): a sidebar of sections and four cards — components, disk space,
/// saves, general. "Stores" opens the Stores screen in the main window, as the design links it. Sections EscApp
/// has nothing for yet (about, auto-retry, the folder for new games) are left out.
struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case general, components, disk, saves
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .general: "General"
            case .components: "Components"
            case .disk: "Disk Space"
            case .saves: "Saves"
            }
        }
    }

    let components: ComponentsModel
    let library: LibraryModel
    @State private var section: Section = .general
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Settings")
                            .font(.system(size: 22, weight: .bold))
                        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                            GridRow(alignment: .top) {
                                ComponentsCard(components: components).id(Section.components)
                                DiskCard(components: components).id(Section.disk)
                            }
                            GridRow(alignment: .top) {
                                SavesCard(profile: components.paths.profile).id(Section.saves)
                                GeneralCard(components: components, library: library).id(Section.general)
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: section) { withAnimation { proxy.scrollTo(section, anchor: .top) } }
            }
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
                        .background(section == item ? Color.navSelected : .clear, in: .rect(cornerRadius: 8))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == item ? .isSelected : [])
            }
            Button {
                library.shownPage = .stores
                openWindow(id: "library")
            } label: {
                Text("Stores")
                    .font(.system(size: 14))
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
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

/// A white card with an uppercase heading, 18/20 padding and 12-pt gaps.
private struct SettingsCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Color.secondaryText)
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

private struct Note: View {
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
        SettingsCard(title: "Components") {
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
            Button("Licenses") { showsLicenses = true }
                .buttonStyle(.plain)
                .font(.system(size: 13))
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

/// Settings' smaller button: 30 high, radius 8, 12-pt sides.
private struct CompactButtonStyle: ButtonStyle {
    var kind: BrandButtonStyle.Kind = .plain

    func makeBody(configuration: Configuration) -> some View {
        BrandButtonStyle(kind: kind, height: 30, radius: 8).makeBody(configuration: configuration)
    }
}

private struct DiskCard: View {
    let components: ComponentsModel

    var body: some View {
        SettingsCard(title: "Disk Space") {
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
        SettingsCard(title: "Saves") {
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
    enum Language: String, CaseIterable {
        case system, russian = "ru", english = "en"

        var title: String {
            switch self {
            case .system: String(localized: "As in macOS")
            case .russian: "Русский"
            case .english: "English"
            }
        }
    }

    let components: ComponentsModel
    let library: LibraryModel
    @State private var language = Language.current
    @State private var languageChanged = false

    var body: some View {
        @Bindable var components = components
        SettingsCard(title: "General") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Language")
                    if languageChanged {
                        Text("Applies after EscApp restarts")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DesignSelect(selection: $language, options: Language.allCases, title: \.title)
                    .onChange(of: language) {
                        language.apply()
                        languageChanged = true
                    }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open .exe files with a double-click")
                    Text("EscApp is the default app for .exe and .msi")
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
            }
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

fileprivate extension GeneralCard.Language {
    static var current: Self {
        let chosen = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String]
        guard let first = chosen?.first, UserDefaults.standard.persistentDomain(
            forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] != nil else { return .system }
        return first.hasPrefix("ru") ? .russian : first.hasPrefix("en") ? .english : .system
    }

    /// The app's own language, like System Settings → Language & Region → Applications.
    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}
