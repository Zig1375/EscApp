import PlavioxKit
import SwiftUI

/// FirstRunReady.dc.html, variant 2: the search is over and the game works. Confetti and rays for a moment,
/// "next time it starts at once", then the cover goes by itself; "Play" doesn't wait.
struct TuningReadyCard: View {
    let launch: LibraryModel.Launch
    let ready: LibraryModel.Launch.Tuning.Ready
    let library: LibraryModel

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Rays()
                if let game = library.game(launch.id) {
                    GameIconTile(game: game, library: library, size: 84, iconSize: 64, radius: 20)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(Color.newText, in: .circle)
                                .overlay { Circle().strokeBorder(Color.cardBackground, lineWidth: 3) }
                                .offset(x: 9, y: 9)
                        }
                        .modifier(PopIn())
                }
            }
            .frame(height: 170)
            Text("Ready — time to play").font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
            Text("Plaviox remembered how to start \(launch.name). From now on it opens much faster.")
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(Color.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Label("Next time: right away, without checking", systemImage: "bolt.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.newText)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Color.newBackground, in: .capsule)
            Button("Play") { library.revealTunedGame(launch.id) }
                .buttonStyle(BrandButtonStyle(kind: .primary, height: 34, radius: 8))
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.cardBackground)
                .shadow(color: Color(red: 40 / 255, green: 30 / 255, blue: 20 / 255).opacity(0.12), radius: 20, y: 14)
        }
        .overlay { Confetti().clipShape(.rect(cornerRadius: 22, style: .continuous)) }
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.cardBorder) }
    }
}

/// FirstRunFailed.dc.html: nothing worked. Plain words first, the most telling reason from the logs, and what
/// the player can do; the attempts themselves are one click away in the detailed sheet.
struct TuningFailedCard: View {
    let launch: LibraryModel.Launch
    let failure: LibraryModel.Launch.Failure
    let library: LibraryModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                ForEach(0..<max(launch.tuning?.order.count ?? 3, 1), id: \.self) { _ in
                    MiniScreen(state: .failed, game: library.game(launch.id), library: library)
                }
            }
            .padding(.vertical, 4)
            Text("\(launch.name) doesn't start yet").font(.system(size: 22, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text("""
                Plaviox tried every setting, but the game closed each time. It isn't something you did — some games \
                need more.
                """)
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(Color.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.danger)
                LaunchSheet.reason(failure)
                    .font(.system(size: 13.5))
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(Color.errorBackground, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.errorBorder) }
            HStack(spacing: 8) {
                Button("Close") { library.cancelLaunch() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy Report") { library.copyReport(failure) }
                if missingFile {
                    Button("Choose Settings Myself") { library.chooseSettingsMyself() }
                    Button("Show Game Folder") {
                        library.showFolder(of: launch.id)
                        library.cancelLaunch()
                    }
                    .buttonStyle(BrandButtonStyle(kind: .primary, height: 32, radius: 8))
                } else {
                    Button("Choose Settings Myself") { library.chooseSettingsMyself() }
                        .buttonStyle(BrandButtonStyle(kind: .primary, height: 32, radius: 8))
                }
            }
            .buttonStyle(BrandButtonStyle(height: 32, radius: 8))
            // The detailed "didn't start" sheet in the main window, with every backend tried.
            Button("Details: what was tried") { library.launch?.tuning = nil }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.brand)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.cardBackground)
                .shadow(color: Color(red: 40 / 255, green: 30 / 255, blue: 20 / 255).opacity(0.12), radius: 20, y: 14)
        }
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.cardBorder) }
    }

    private var missingFile: Bool {
        if case .missingFile? = failure.problem { true } else { false }
    }
}

/// Grows in with a little overshoot.
private struct PopIn: ViewModifier {
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown || reduceMotion ? 1 : 0.5)
            .opacity(shown || reduceMotion ? 1 : 0)
            .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { shown = true } }
    }
}

/// Soft amber rays turning slowly behind the game's icon.
private struct Rays: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 12) / 12 * 360
            Canvas { canvas, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2
                for index in 0..<12 {
                    let start = Angle.degrees(angle + Double(index) * 30)
                    var ray = Path()
                    ray.move(to: center)
                    ray.addArc(center: center, radius: radius, startAngle: start, endAngle: start + .degrees(11),
                               clockwise: false)
                    ray.closeSubpath()
                    canvas.fill(ray, with: .color(Color.brand.opacity(0.10)))
                }
            }
            .frame(width: 170, height: 170)
        }
        .accessibilityHidden(true)
    }
}

/// Confetti falling over the card for its first seconds; none with Reduce Motion.
private struct Confetti: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    private static let colors: [Color] = [.brand, .newText, .danger, Color(red: 0.88, green: 0.64, blue: 0.11),
                                          Color(red: 0.24, green: 0.44, blue: 0.69)]
    /// Each piece: where it starts across, how long it falls, when it starts, how much it sways and spins.
    private struct Piece {
        var x, duration, delay, sway, spin: Double
    }

    private static let pieces: [Piece] = (0..<46).map { index in
        let seed = Double(index)
        return Piece(x: (seed * 0.618).truncatingRemainder(dividingBy: 1),
                     duration: 1.9 + (seed * 0.37).truncatingRemainder(dividingBy: 1.2),
                     delay: (seed * 0.29).truncatingRemainder(dividingBy: 1.1),
                     sway: 10 + (seed * 3.1).truncatingRemainder(dividingBy: 18),
                     spin: 200 + (seed * 47).truncatingRemainder(dividingBy: 400))
    }

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSince(start)
                Canvas { canvas, size in
                    for (index, piece) in Self.pieces.enumerated() {
                        let time = elapsed - piece.delay
                        guard time > 0, time < piece.duration else { continue }
                        let progress = time / piece.duration
                        let x = piece.x * size.width + sin(time * 4 + Double(index)) * piece.sway
                        let y = -12 + progress * (size.height + 24)
                        var piecePath = Path(roundedRect: CGRect(x: -3, y: -5, width: 6, height: 10), cornerRadius: 1.5)
                        piecePath = piecePath.applying(CGAffineTransform(rotationAngle: time * piece.spin * .pi / 180))
                            .applying(CGAffineTransform(translationX: x, y: y))
                        canvas.fill(piecePath, with: .color(Self.colors[index % Self.colors.count]
                                                        .opacity(1 - max(progress - 0.75, 0) * 4)))
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
