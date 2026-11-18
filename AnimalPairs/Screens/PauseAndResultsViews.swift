import AnimalPairsCore
import SwiftUI

struct PauseOverlay: View {
    let session: GameSession
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.localizer
        ZStack {
            Palette.brown.opacity(0.35).ignoresSafeArea()
                .accessibilityHidden(true)
            Panel {
                VStack(spacing: 18) {
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Palette.lavenderDeep)
                        .accessibilityHidden(true)
                    Text(t["pause.title"])
                        .font(.rounded(.largeTitle, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Button {
                        session.resumeFromPauseMenu()
                    } label: {
                        Label(t["pause.resume"], systemImage: "play.fill").frame(minWidth: 220)
                    }
                    .buttonStyle(PillowButtonStyle(kind: .mint))
                    Button {
                        model.restartCurrentGame()
                    } label: {
                        Label(t["pause.restart"], systemImage: "arrow.counterclockwise").frame(minWidth: 220)
                    }
                    .buttonStyle(PillowButtonStyle(kind: .secondary))
                    Button {
                        model.goHome()
                    } label: {
                        Label(t["common.home"], systemImage: "house.fill").frame(minWidth: 220)
                    }
                    .buttonStyle(PillowButtonStyle(kind: .secondary))
                }
            }
            .frame(maxWidth: 440)
            .padding(24)
        }
        .accessibilityAddTraits(.isModal)
    }
}

struct ResultsView: View {
    let summary: RoundSummary
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.localizer
        ZStack {
            FloralCorners()
            Confetti()
            ScrollView {
                VStack(spacing: 22) {
                    Spacer(minLength: 24)
                    TrophyBadge(ribbonText: t["results.ribbon"])
                        .frame(maxWidth: 420, maxHeight: 360)
                        .background { ResultsStickers() }
                        .overlay { ResultsMascot() }
                    Text(t["results.title"])
                        .font(.rounded(.largeTitle, weight: .heavy))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(t("results.subtitle", summary.pairCount))
                        .font(.rounded(.title3, weight: .medium))
                        .foregroundStyle(Palette.brownSoft)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 16) {
                        StatBubble(systemImage: "hand.tap.fill", text: t("results.tries", summary.attempts))
                        StatBubble(systemImage: "lightbulb.fill", text: t("results.hints", summary.hintsUsed))
                    }

                    VStack(spacing: 14) {
                        Button {
                            model.playAgain(summary.configuration)
                        } label: {
                            Label(t["results.playAgain"], systemImage: "arrow.counterclockwise").frame(minWidth: 260)
                        }
                        .buttonStyle(PillowButtonStyle(kind: .primary))
                        Button {
                            model.goToSetup()
                        } label: {
                            Label(t["results.chooseBoard"], systemImage: "square.grid.2x2.fill").frame(minWidth: 260)
                        }
                        .buttonStyle(PillowButtonStyle(kind: .secondary))
                        Button {
                            model.goHome()
                        } label: {
                            Label(t["common.home"], systemImage: "house.fill").frame(minWidth: 260)
                        }
                        .buttonStyle(PillowButtonStyle(kind: .secondary))
                    }
                    Spacer(minLength: 24)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            // The ending jingle with soft confetti under it. star_earn,
            // badge_reveal and new_best stay unused: the game has no stars,
            // badges or best scores.
            model.audio.play(.completionJingle)
            model.audio.play(.confetti, after: 0.4)
            model.audio.narrate(.completed, after: 3.1)
        }
    }
}

/// Clay stickers around the trophy's outer edges, drawn behind it. They stay
/// clear of the ribbon text (centre bottom) and of everything below the trophy.
private struct ResultsStickers: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            StickerArt(sticker: .sparkles)
                .frame(width: w * 0.2, height: w * 0.2)
                .position(x: w * 0.1, y: h * 0.16)
            StickerArt(sticker: .confetti)
                .frame(width: w * 0.22, height: w * 0.22)
                .position(x: w * 0.9, y: h * 0.14)
            StickerArt(sticker: .rainbow)
                .frame(width: w * 0.22, height: w * 0.16)
                .position(x: w * 0.09, y: h * 0.74)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The Little Penguin Studio mascot holding a star, at the trophy's lower
/// right (right of the ribbon). Gentle bob, off under Reduce Motion.
private struct ResultsMascot: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            MascotArt(pose: .star, bob: true)
                .frame(width: w * 0.28, height: w * 0.28)
                .position(x: w * 0.92, y: h * 0.72)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct StatBubble: View {
    let systemImage: String
    let text: String
    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.rounded(.title3, weight: .semibold))
            .padding(.horizontal, 20)
            .frame(minHeight: Metrics.touchTarget)
            .background(Capsule().fill(Palette.cream).shadow(color: Palette.shadow, radius: 4, y: 2))
    }
}

/// Soft falling shapes. Static when Reduce Motion is on.
private struct Confetti: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fall = false
    private let pieces: [(x: CGFloat, delay: Double, symbol: String, color: Color, size: CGFloat)] = (0..<26).map { i in
        let symbols = ["heart.fill", "star.fill", "pawprint.fill", "circle.fill"]
        let colors = [Palette.peach, Palette.mint, Palette.lavender, Palette.honey]
        return (CGFloat((i * 37) % 100) / 100, Double(i % 7) * 0.35, symbols[i % 4], colors[(i / 2) % 4], CGFloat(16 + (i * 7) % 18))
    }

    var body: some View {
        GeometryReader { proxy in
            ForEach(pieces.indices, id: \.self) { i in
                let piece = pieces[i]
                Image(systemName: piece.symbol)
                    .font(.system(size: piece.size))
                    .foregroundStyle(piece.color)
                    .position(x: piece.x * proxy.size.width,
                              y: reduceMotion ? CGFloat((i * 53) % 100) / 100 * proxy.size.height
                                              : (fall ? proxy.size.height + 40 : -40))
                    .animation(reduceMotion ? nil : .linear(duration: 5).delay(piece.delay).repeatForever(autoreverses: false), value: fall)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { fall = true }
    }
}
