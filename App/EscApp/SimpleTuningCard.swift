import EscAppKit
import SwiftUI

/// The first-launch screen as most players see it: what EscApp is doing and why, in plain words, a picture of it
/// trying settings until one works, and a bar. The steps and attempts themselves are behind "Details".
struct SimpleTuningCard: View {
    let launch: LibraryModel.Launch
    let tuning: LibraryModel.Launch.Tuning
    let library: LibraryModel
    let details: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            TuningIllustration(game: library.game(launch.id), library: library)
                .padding(.top, 6)
            VStack(spacing: 8) {
                Text("Getting \(launch.name) ready for its first launch")
                    .font(.system(size: 22, weight: .bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("""
                    This game was made for Windows. EscApp tries it with different settings and checks that it \
                    opens and runs smoothly. The one that works is kept, so next time the game starts right away.
                    """)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(Color.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 12) {
                Point(symbol: "magnifyingglass", title: "Looking at the game", detail: "What it needs to run")
                Point(symbol: "slider.horizontal.3", title: "Trying settings",
                      detail: "Its window stays hidden meanwhile")
                Point(symbol: "checkmark.seal", title: "Keeping the best", detail: "Only needed once")
            }
            // All three as tall as the tallest.
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                TimeBar(startedAt: tuning.startedAt)
                Text("Usually under a minute").modifier(TuningHint())
            }
            HStack {
                Button("Cancel") { library.cancelLaunch() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Details", action: details)
            }
            .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
        }
        .padding(28)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.cardBackground)
                .shadow(color: Color(red: 40 / 255, green: 30 / 255, blue: 20 / 255).opacity(0.12), radius: 20, y: 14)
        }
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.cardBorder) }
        .accessibilityElement(children: .contain)
    }
}

/// One of the three things EscApp does, with its icon.
private struct Point: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.brand)
                .frame(width: 40, height: 40)
                .background(Color.navSelected, in: .circle)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).modifier(TuningHint()).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(Color.windowBackground, in: .rect(cornerRadius: 14, style: .continuous))
    }
}

/// Fills with time rather than with attempts: quickly at first, then ever slower, never quite full. How many
/// attempts a game needs isn't known in advance, and a bar that jumps back would say something went wrong.
private struct TimeBar: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let fraction = Self.fraction(after: context.date.timeIntervalSince(startedAt))
            Capsule()
                .fill(Color.track)
                .frame(height: 8)
                .overlay(alignment: .leading) {
                    GeometryReader { bar in
                        Capsule()
                            .fill(LinearGradient(colors: [Color.brand.opacity(0.75), Color.brand],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(bar.size.width * fraction, 8))
                    }
                }
                .animation(.linear(duration: 0.5), value: fraction)
                .accessibilityElement()
                .accessibilityLabel("Getting the game ready")
                .accessibilityValue(Text(fraction.formatted(.percent.precision(.fractionLength(0)))))
        }
    }

    /// About half after 20 s, 80% after 45 s, at most 95%.
    static func fraction(after seconds: TimeInterval) -> Double {
        min(1 - exp(-max(seconds, 0) / 28), 0.95)
    }
}

/// Three little screens, the game tried on each in turn: the first two don't work, the settings change, the third
/// one does. Plays over and over while EscApp searches; still with Reduce Motion.
private struct TuningIllustration: View {
    let game: GameRecord?
    let library: LibraryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seconds per screen.
    static let step: TimeInterval = 1.8

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion)) { context in
            let time = reduceMotion ? Self.step * 3.5
                : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.step * 4.5)
            HStack(spacing: 10) {
                ForEach(0..<3) { index in
                    if index > 0 {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(time >= Self.step * Double(index) ? Color.brand : Color.track)
                    }
                    MiniScreen(state: state(of: index, at: time), game: game, library: library)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: Int(time / (Self.step / 2)))
        }
        .accessibilityHidden(true)
    }

    private func state(of index: Int, at time: TimeInterval) -> MiniScreen.State {
        let start = Self.step * Double(index)
        if time < start { return .waiting }
        if time < start + Self.step * 0.55 { return .trying }
        return index == 2 ? .works : .failed
    }
}

struct MiniScreen: View {
    enum State { case waiting, trying, failed, works }

    let state: State
    let game: GameRecord?
    let library: LibraryModel

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                HStack(spacing: 3) {
                    ForEach(0..<3) { _ in Circle().fill(Color.track).frame(width: 5, height: 5) }
                    Spacer()
                }
                .padding(.horizontal, 7)
                .frame(height: 13)
                ZStack {
                    if let game, state != .waiting {
                        GameIconTile(game: game, library: library, size: 40, iconSize: 30, radius: 10)
                            .opacity(state == .failed ? 0.35 : 1)
                            .scaleEffect(state == .works ? 1.12 : 1)
                    } else {
                        Image(systemName: "gamecontroller")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.track)
                    }
                    badge.offset(x: 22, y: 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { if state == .trying { ScanBeam() } }
                .clipped()
            }
            .frame(width: 118, height: 84)
            .background(Color.windowBackground, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(border, lineWidth: state == .waiting ? 1 : 2)
            }
            Text(caption)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(captionColor)
        }
    }

    @ViewBuilder private var badge: some View {
        switch state {
        case .failed: mark("xmark", background: .errorBackground, foreground: .danger)
        case .works: mark("checkmark", background: .newBackground, foreground: .newText)
        case .trying, .waiting: EmptyView()
        }
    }

    private func mark(_ symbol: String, background: Color, foreground: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(foreground)
            .frame(width: 20, height: 20)
            .background(background, in: .circle)
            .overlay { Circle().strokeBorder(Color.cardBackground, lineWidth: 2) }
            .transition(.scale.combined(with: .opacity))
    }

    private var border: Color {
        switch state {
        case .waiting: .cardBorder
        case .trying: .warnBorder
        case .failed: .errorBorder
        case .works: .newText.opacity(0.5)
        }
    }

    private var caption: LocalizedStringKey {
        switch state {
        case .waiting: "Next"
        case .trying: "Trying…"
        case .failed: "Didn't work"
        case .works: "Works!"
        }
    }

    private var captionColor: Color {
        switch state {
        case .waiting: .secondaryText
        case .trying: .warnText
        case .failed: .danger
        case .works: .newText
        }
    }
}

/// FirstRunSimple.dc.html, variant A: a beam sweeping the screen while the game is being tried on it.
private struct ScanBeam: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            GeometryReader { box in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                // Down and back up, easing at the ends.
                let position = (1 - cos(phase * 2 * .pi)) / 2
                Rectangle()
                    .fill(Color.brand.opacity(0.85))
                    .frame(height: 2)
                    .shadow(color: Color.brand.opacity(0.5), radius: 4)
                    .offset(y: box.size.height * position)
            }
        }
        .allowsHitTesting(false)
    }
}
