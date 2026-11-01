import PlavioxKit
import SwiftUI

/// Advanced.dc.html: a game's settings that usually need no changing. Graphics and display on the left, controls
/// and launch on the right, the game's Windows below. Every setting applies at the next launch.
struct AdvancedPage: View {
    let id: GameID
    let library: LibraryModel
    @State private var arguments = ""
    @State private var environment = ""
    @State private var size: (unique: Int64, apparent: Int64)?
    @State private var confirmingReset = false

    var body: some View {
        Group {
            if let game = library.game(id) {
                content(game)
                    .task(id: game.id) {
                        arguments = game.arguments ?? ""
                        environment = game.environment ?? ""
                        size = await library.bottleSize(of: game.id)
                    }
                    .alert("Reset the Windows of \(game.name)?", isPresented: $confirmingReset) {
                        Button("Reset", role: .destructive) {
                            library.resetWindows(of: game)
                            size = nil
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("""
                            The game gets a clean Windows at its next launch. What was set up inside it (registry, \
                            installed components) goes; saves and the game itself stay.
                            """)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.windowBackground)
    }

    private func content(_ game: GameRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Advanced").font(.system(size: 22, weight: .bold))
                if library.isPlaying(game.id) { ClosedGameNote() }
                HStack(alignment: .top, spacing: 16) {
                    graphics(game)
                    controls(game)
                }
                .disabled(library.isPlaying(game.id))
                windows(game)
                Text(GameSettings.canReset(game, paths: library.paths)
                     ? "A reset makes a clean Windows for the game. Saves and the game itself stay."
                     : "This game is installed inside its own Windows: a reset would delete it.")
                    .modifier(Hint())
                    .padding(.top, -6)
                LaunchSettingsCard(game: game, library: library)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
    }

    // MARK: Graphics

    private func graphics(_ game: GameRecord) -> some View {
        Card(title: "Graphics") {
            Segmented(selection: Binding(get: { game.chosenBackend }, set: { backend in
                library.changeSetting(of: game.id) { $0.chosenBackend = backend }
            }), options: [nil] + GraphicsBackend.allCases.map { $0 }) { $0?.displayName ?? String(localized: "Auto") }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Graphics")
            Text(backendHint(game)).modifier(Hint())
            SettingRow(title: "Enlarge low resolutions", detail: scalingHint(game)) {
                Segmented(selection: setting(game, \.scaling), options: GameScaling.Setting.allCases,
                          title: Self.settingTitle)
                    .frame(width: 190)
            }
            SettingRow(title: "Frame counter", detail: "Metal HUD over the game") {
                Switch(isOn: flag(game, \.fpsCounter))
            }
        }
    }

    private func backendHint(_ game: GameRecord) -> LocalizedStringKey {
        if let chosen = game.chosenBackend {
            return "The game always starts with \(chosen.displayName); it isn't retried with others if it fails."
        }
        guard let info = library.infos[game.id], let (backend, reason) = GameSettings.autoBackend(for: game,
                                                                                                    info: info)
        else { return "Auto picks the graphics from what the game uses." }
        let name = backend.displayName
        let why: LocalizedStringKey = switch reason {
        case .workedBefore: "Auto now picks \(name): it worked for this game last time. \(Self.byHand)"
        case .directDraw: "Auto now picks \(name): the game uses DirectDraw. \(Self.byHand)"
        case .directX9: "Auto now picks \(name): the game uses DirectX 9. \(Self.byHand)"
        case .directX11: "Auto now picks \(name): the game uses DirectX 11. \(Self.byHand)"
        case .directX12: "Auto now picks \(name): the game uses DirectX 12. \(Self.byHand)"
        case .noDirectX: "Auto now picks \(name): the game draws without DirectX. \(Self.byHand)"
        }
        return why
    }

    private func scalingHint(_ game: GameRecord) -> LocalizedStringKey {
        switch game.scaling ?? .auto {
        case .on: return "Small game windows are enlarged as much as fits on the screen"
        case .off: return "The game's window keeps its own size. Full-screen games still fill the screen."
        case .auto: break
        }
        // A store's client shares the game's bottle, and one that can't draw in Retina mode takes the game's
        // with it (`StoreClient.retina`).
        let dpiAware = library.infos[game.id]?.dpiAware ?? false
        let retina = StoreClient.retina(GameSettings.retina(game.retina, dpiAware: dpiAware), for: game.store)
        switch GameSettings.autoScaling(for: game, retina: retina) {
        case .notSeenYet:
            return "Auto: decided after the first launch, from the size of the game's window"
        case .fullScreen:
            return "Auto now: the game runs full screen; it fills the screen and the Mac's display isn't switched"
        case let .enlarged(width, height, scale):
            let times = scale.formatted(.number.precision(.fractionLength(0...1)))
            return """
                Auto now: on — the game's window is \(width)×\(height), Plaviox enlarges it \(times)× and leaves the \
                Mac's display alone
                """
        case let .largeEnough(width, height):
            return "Auto now: off — the game's window, \(width)×\(height), is large enough"
        case .drawsForRetina:
            return "Auto now: off — the game draws for Retina itself"
        }
    }

    // MARK: Controls and launch

    private func controls(_ game: GameRecord) -> some View {
        Card(title: "Controls and launch") {
            SettingRow(title: "⌘ works as Ctrl", detail: "Ctrl+S, Ctrl+C and other shortcuts with ⌘") {
                Switch(isOn: Binding(get: { game.commandAsControl != false }, set: { value in
                    library.changeSetting(of: game.id) { $0.commandAsControl = value ? nil : false }
                }))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Launch parameters").font(.system(size: 14))
                TextField("", text: $arguments)
                    .textFieldStyle(.plain)
                    .modifier(FieldStyle())
                    .onChange(of: arguments) { save(\.arguments, arguments) }
                    .accessibilityLabel("Launch parameters")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Environment variables").font(.system(size: 14))
                TextEditor(text: $environment)
                    .scrollContentBackground(.hidden)
                    .frame(height: 54)
                    .overlay(alignment: .topLeading) {
                        if environment.isEmpty {
                            Text(verbatim: "# " + String(localized: "one variable per line: NAME=value"))
                                .foregroundStyle(Color.secondaryText)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .modifier(FieldStyle())
                    .onChange(of: environment) { save(\.environment, environment) }
                    .accessibilityLabel("Environment variables")
            }
            if game.store == nil {
                // A store game shares its store's Windows with the client, which must run the same way.
                SettingRow(title: "Fast sync", detail: "Usually faster; turn it off if the game freezes") {
                    Switch(isOn: Binding(get: { game.fastSync != false }, set: { value in
                        library.changeSetting(of: game.id) { $0.fastSync = value ? nil : false }
                    }))
                }
            }
            SettingRow(title: "Verbose log", detail: "For diagnosing problems; the game may run slower") {
                Switch(isOn: flag(game, \.verboseLog))
            }
        }
    }

    // MARK: The game's Windows

    private func windows(_ game: GameRecord) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("This game's Windows: \(size.map { $0.unique.formatted(.byteCount(style: .file)) } ?? "—")")
                    .font(.system(size: 14, weight: .semibold))
                if let size {
                    let finder = size.apparent.formatted(.byteCount(style: .file))
                    Text("Real size on disk. Finder shows about \(finder): most of it is shared with other games.")
                        .modifier(Hint())
                } else {
                    Text("Made at the game's next launch.").modifier(Hint())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            let log = library.latestLog(for: game)
            Button("Open Last Log") { if let log { library.openLog(log) } }
                .disabled(log == nil)
            Button("Copy Report") { library.copyLastReport(for: game) }
                .disabled(log == nil)
            Button("Reset Windows…") { confirmingReset = true }
                .buttonStyle(BrandButtonStyle(kind: .danger, height: 32, radius: 8))
                .disabled(!GameSettings.canReset(game, paths: library.paths) || library.isPlaying(game.id)
                          || size == nil)
        }
        .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
        .padding(20)
        .background(Color.cardBackground, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cardBorder) }
    }

    // MARK: Bindings

    private func setting(_ game: GameRecord,
                         _ path: WritableKeyPath<GameRecord, GameScaling.Setting?>) -> Binding<GameScaling.Setting> {
        Binding(get: { game[keyPath: path] ?? .auto }, set: { value in
            library.changeSetting(of: game.id) { $0[keyPath: path] = value == .auto ? nil : value }
        })
    }

    private func flag(_ game: GameRecord, _ path: WritableKeyPath<GameRecord, Bool?>) -> Binding<Bool> {
        Binding(get: { game[keyPath: path] ?? false }, set: { value in
            library.changeSetting(of: game.id) { $0[keyPath: path] = value ? true : nil }
        })
    }

    private func save(_ path: WritableKeyPath<GameRecord, String?>, _ text: String) {
        guard let game = library.game(id), (game[keyPath: path] ?? "") != text else { return }
        library.changeSetting(of: id) { $0[keyPath: path] = text.isEmpty ? nil : text }
    }

    static let byHand = String(localized: "If you pick one yourself, retrying after a failure is turned off.")

    static func settingTitle(_ setting: GameScaling.Setting) -> String {
        switch setting {
        case .auto: String(localized: "Auto")
        case .on: String(localized: "On")
        case .off: String(localized: "Off")
        }
    }
}

/// The design's white card with an uppercase title.
private struct Card<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Color.secondaryText)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cardBorder) }
    }
}

/// A setting's name and explanation on the left, its control on the right.
private struct SettingRow<Control: View>: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14))
                Text(detail).modifier(Hint())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
                .accessibilityElement(children: .contain)
                .accessibilityLabel(title)
        }
    }
}

/// The design's segmented control: a beige track, the chosen option on a white raised pill.
private struct Segmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let chosen = option == selection
                Button { selection = option } label: {
                    Text(title(option))
                        .font(.system(size: 13, weight: chosen ? .semibold : .regular))
                        .foregroundStyle(chosen ? Color.primary : Color.bodyText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background {
                            if chosen {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.cardBackground)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Color.chip, in: .rect(cornerRadius: 9, style: .continuous))
        // Plain buttons look the same when disabled; without this a locked choice looked clickable.
        .modifier(DimmedWhenDisabled())
    }
}

/// The design's switch: 38×22, amber when on.
private struct Switch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule()
                .fill(isOn ? Color.brand : Color.buttonBorder)
                .frame(width: 38, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 18, height: 18).padding(2)
                }
                .animation(.easeOut(duration: 0.12), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
        .accessibilityAddTraits(.isToggle)
        .modifier(DimmedWhenDisabled())
    }
}

private struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, design: .monospaced))
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(Color.fieldBackground, in: .rect(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.buttonBorder) }
    }
}

private struct Hint: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12))
            .foregroundStyle(Color.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Advanced.dc.html's header: back to the game, and a reminder that this is rarely needed.
struct AdvancedHeader: View {
    let name: String
    let back: () -> Void

    var body: some View {
        Button(action: back) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text(verbatim: name)
            }
        }
        .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
        Spacer(minLength: 0)
        Text("Usually nothing here needs changing")
            .font(.system(size: 12))
            .foregroundStyle(Color.secondaryText)
    }
}
