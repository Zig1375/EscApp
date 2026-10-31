import SwiftUI

/// Under a game's actions while EscApp can't see game windows: one quiet line and the way to allow it. A first
/// launch then guesses a frozen game from its window's size and CPU, and a game stuck on black can pass as working.
/// It stays small on purpose: the game plays either way, and the window after setup already asked once.
struct ScreenAccessNote: View {
    @State private var allowed: Bool

    /// `allowed` is for snapshots (`ScreenAccessSnapshots`); the line itself follows the permission.
    init(allowed: Bool? = nil) {
        _allowed = State(initialValue: allowed ?? ScreenAccess.allowed)
    }

    var body: some View {
        Group {
            if !allowed {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "eye.slash")
                        .accessibilityHidden(true)
                    Text("EscApp can't see game windows yet, so it may not find the right settings by itself.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Allow…") { ScreenAccess.show() }
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.brand)
                        .fixedSize()
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .frame(maxWidth: 460, alignment: .leading)
            }
        }
        // System Settings is where the switch is: the line goes once it is on.
        .task {
            while !Task.isCancelled {
                allowed = ScreenAccess.allowed
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// On the first-launch screen while EscApp can't see game windows: the search it shows can't be trusted to find
/// settings that work, since a game frozen on a black window may look like it runs. "Allow…" opens the steps over
/// the cover (`ScreenAccess.show`).
struct ScreenAccessWarning: View {
    private let allowed: Bool

    /// `allowed` is for snapshots (`ScreenAccessSnapshots`).
    init(allowed: Bool = ScreenAccess.allowed) {
        self.allowed = allowed
    }

    var body: some View {
        if !allowed {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("EscApp can't see game windows")
                        .fontWeight(.semibold)
                    Text("""
                        Without the Screen Recording permission, EscApp can't guarantee that the settings it finds \
                        really work: a game stuck on a black screen may look like it runs.
                        """)
                        .fixedSize(horizontal: false, vertical: true)
                    // The steps window opens over the cover; once the switch is on macOS reopens EscApp, which
                    // ends this search, and the next launch searches again with the picture.
                    Button("Allow…") { ScreenAccess.show() }
                        .buttonStyle(CompactButtonStyle(kind: .primary))
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 13))
            .foregroundStyle(Color.warnText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.warnBackground, in: .rect(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.warnBorder) }
            .accessibilityElement(children: .combine)
        }
    }
}
