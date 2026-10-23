import SwiftUI

extension Color {
    /// ExePort's amber. Read from the asset directly: `Color.accentColor` follows the user's system accent
    /// (often blue) unless they picked "Multicolour", and the brand colour should stay the same everywhere.
    static let brand = Color("AccentColor")
}

/// The big app-icon-like tile at the top of the empty library and the setup screen.
struct BrandHero: View {
    var symbol = "gamecontroller.fill"
    var size: CGFloat = 104

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.93, green: 0.58, blue: 0.24),
                                          Color(red: 0.54, green: 0.22, blue: 0.03)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            }
            .frame(width: size, height: size)
            .shadow(color: Color(red: 0.54, green: 0.22, blue: 0.03).opacity(0.45), radius: 18, y: 10)
            .accessibilityHidden(true)
    }
}

/// A soft warm glow from the top of the window, so empty screens don't look like a blank page.
struct WarmBackground: View {
    var body: some View {
        RadialGradient(colors: [Color.brand.opacity(0.16), .clear],
                       center: .top, startRadius: 0, endRadius: 560)
            .ignoresSafeArea()
    }
}

#Preview {
    BrandHero().padding(40)
}
