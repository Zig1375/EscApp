import SwiftUI

/// The design's colours (Main.dc.html, Game.dc.html), with dark counterparts, from the asset catalog.
extension Color {
    static let windowBackground = Color("WindowBackground")
    static let toolbarBackground = Color("ToolbarBackground")
    static let cardBackground = Color("CardBackground")
    static let cardBorder = Color("CardBorder")
    static let cardBorderHover = Color("CardBorderHover")
    static let rowDivider = Color("Divider")
    static let secondaryText = Color("SecondaryText")
    static let chip = Color("Chip")
    static let chipSelected = Color("ChipSelected")
    static let chipSelectedText = Color("ChipSelectedText")
    static let brandButton = Color("BrandButton")
    static let buttonBorder = Color("ButtonBorder")
    static let infoBackground = Color("InfoBackground")
    static let infoBorder = Color("InfoBorder")
    static let infoText = Color("InfoText")
    static let newBackground = Color("NewBackground")
    static let newText = Color("NewText")
    static let danger = Color("Danger")
    static let dangerBorder = Color("DangerBorder")
    static let navSelected = Color("NavSelected")
    static let navSelectedText = Color("NavSelectedText")
    static let sidebar = Color("Sidebar")
    static let okText = Color("OkText")
    static let diskTemplate = Color("DiskTemplate")
    static let diskGames = Color("DiskGames")
    static let track = Color("Track")
    /// Launching.dc.html: the "trying again" box and the "nothing helped" box.
    static let warnBackground = Color("WarnBackground")
    static let warnBorder = Color("WarnBorder")
    static let warnText = Color("WarnText")
    static let errorBackground = Color("ErrorBackground")
    static let errorBorder = Color("ErrorBorder")
    /// Installer.dc.html: the "Installer" tag, the green number of the last step, the folder field, body text.
    static let installerTag = Color("InstallerTag")
    static let installerTagText = Color("InstallerTagText")
    static let stepDone = Color("StepDone")
    static let fieldBackground = Color("FieldBackground")
    static let bodyText = Color("BodyText")
}

/// The design's two button looks: white with a thin border, and the amber primary.
struct BrandButtonStyle: ButtonStyle {
    /// `destructive` is filled red: the confirm button of a delete that takes games with it.
    enum Kind { case plain, primary, danger, destructive }

    var kind: Kind = .plain
    var height: CGFloat = 34
    var small = false
    /// Icon-only, no side padding (the settings button).
    var square = false
    /// Main.dc.html uses 9, Game.dc.html 8.
    var radius: CGFloat = 9
    /// As wide as it is given, label centred: the game card's two buttons, one above the other.
    var fill = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: small ? 12 : 13, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, square ? 0 : small ? 10 : 14)
            .frame(maxWidth: fill ? .infinity : nil)
            .frame(height: small ? 26 : height)
            .background(background.opacity(configuration.isPressed ? 0.85 : 1),
                        in: .rect(cornerRadius: small ? 7 : radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: small ? 7 : radius, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            }
            .contentShape(.rect)
            .modifier(DimmedWhenDisabled())
    }

    private var foreground: Color {
        switch kind {
        case .plain: .primary
        case .primary, .destructive: .white
        case .danger: .danger
        }
    }

    private var background: Color {
        switch kind {
        case .primary: .brandButton
        case .destructive: .danger
        case .plain, .danger: .cardBackground
        }
    }

    private var border: Color {
        switch kind {
        case .plain: .buttonBorder
        case .primary: .brandButton
        case .danger: .dangerBorder
        case .destructive: .danger
        }
    }
}

/// Controls drawn by the app look the same whether or not they can be used; "Change" on a running game's page
/// looked clickable and did nothing.
struct DimmedWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.opacity(isEnabled ? 1 : 0.45)
    }
}

extension ButtonStyle where Self == BrandButtonStyle {
    static var brand: BrandButtonStyle { BrandButtonStyle() }
    static var brandPrimary: BrandButtonStyle { BrandButtonStyle(kind: .primary) }
}

/// The design's <select>: white, a 1-pt border, radius 7, 28 high, the value and an up-down chevron.
struct DesignSelect<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var width: CGFloat?

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(options, id: \.self) { Text(title($0)).tag($0) }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Text(title(selection)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .frame(width: width, height: 28)
            .background(Color.cardBackground, in: .rect(cornerRadius: 7, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.buttonBorder) }
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(DimmedWhenDisabled())
    }
}
