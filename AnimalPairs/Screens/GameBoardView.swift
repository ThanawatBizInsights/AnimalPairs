import AnimalPairsCore
import SwiftUI

struct GameBoardView: View {
    let session: GameSession
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.localizer
        let state = session.state
        VStack(spacing: 12) {
            GameHeader(session: session)
                .padding(.horizontal, 20)
                .padding(.top, 8)

            CardGrid(session: session)
                .padding(.horizontal, 16)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(t["board.cards"]))

            Button {
                session.hint()
            } label: {
                Label(t["board.hint"], systemImage: "lightbulb.fill")
            }
            .buttonStyle(PillowButtonStyle(kind: .secondary))
            .disabled(state.isInputLocked)
            .accessibilityHint(Text(t["board.hint.hint"]))
            .padding(.bottom, 16)
        }
        .overlay {
            if session.isPauseMenuVisible {
                PauseOverlay(session: session)
            }
        }
    }
}

private struct GameHeader: View {
    let session: GameSession
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.localizer
        let state = session.state
        HStack(spacing: 16) {
            RoundIconButton(systemImage: "pause.fill", label: t["board.pause"]) { session.showPauseMenu() }

            Spacer(minLength: 8)

            VStack(spacing: 6) {
                Text(t("board.progress", state.matchedPairs, state.totalPairs))
                    .font(.rounded(.title3, weight: .bold))
                    .multilineTextAlignment(.center)
                PairDots(matched: state.matchedPairs, total: state.totalPairs)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            RoundIconButton(systemImage: model.settings.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                            label: model.settings.soundEnabled ? t["board.sound.on"] : t["board.sound.off"]) {
                model.setSoundEnabled(!model.settings.soundEnabled)
            }
            .accessibilityHint(Text(t["board.sound.hint"]))
        }
    }
}

private struct PairDots: View {
    let matched: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { index in
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(index < matched ? Palette.mintDeep : Palette.lavender)
            }
        }
    }
}

/// Fixed row-major grid. Card positions depend only on board order, so
/// rotating or resizing the window rescales cards without moving them.
private struct CardGrid: View {
    let session: GameSession

    var body: some View {
        let state = session.state
        let columns = state.configuration.boardSize.columns
        let rows = state.configuration.boardSize.rows
        GeometryReader { proxy in
            let spacing = max(6, min(18, min(proxy.size.width, proxy.size.height) * 0.02))
            let cellWidth = (proxy.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let cellHeight = (proxy.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            let aspect = CardGeometry.aspect
            let width = max(44, min(cellWidth, cellHeight * aspect))
            let height = max(44, width / aspect)
            VStack(spacing: spacing) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<columns, id: \.self) { column in
                            let index = row * columns + column
                            if index < state.tiles.count {
                                let tile = state.tiles[index]
                                CardView(tile: tile,
                                         artwork: session.artwork(for: tile),
                                         isHighlighted: session.highlightedTiles.contains(tile.id),
                                         isLocked: state.isInputLocked,
                                         position: CardPosition(index: index, row: row, column: column),
                                         cornerRadius: width * CardGeometry.cornerRatio)
                                    .frame(width: width, height: height)
                                    .onTapGesture { session.tap(tile.id) }
                                    .accessibilityAction { session.tap(tile.id) }
                            }
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// Card proportions taken from the supplied card-back artwork, so the back is
/// never stretched and the face lines up with it when a card flips.
enum CardGeometry {
    /// Width ÷ height of `card_back` (753 × 1024).
    static let aspect: CGFloat = 0.735
    /// Corner radius as a fraction of card width, matching the artwork.
    static let cornerRatio: CGFloat = 0.17
}

struct CardPosition: Equatable {
    let index: Int
    let row: Int
    let column: Int
}

struct CardView: View {
    let tile: Tile
    let artwork: ArtworkDefinition?
    let isHighlighted: Bool
    let isLocked: Bool
    let position: CardPosition
    let cornerRadius: CGFloat

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var pulse = false

    private var isFaceUp: Bool { tile.face != .covered }

    var body: some View {
        let corner = cornerRadius
        ZStack {
            CardBack(corner: corner)
                .opacity(isFaceUp ? 0 : 1)
                .rotation3DEffect(.degrees(reduceMotion ? 0 : (isFaceUp ? 180 : 0)), axis: (x: 0, y: 1, z: 0))
            CardFace(artwork: artwork, matched: tile.face == .matched, corner: corner)
                .opacity(isFaceUp ? 1 : 0)
                .rotation3DEffect(.degrees(reduceMotion ? 0 : (isFaceUp ? 0 : -180)), axis: (x: 0, y: 1, z: 0))
        }
        .overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Palette.honey, style: StrokeStyle(lineWidth: pulse && !reduceMotion ? 8 : 6, dash: reduceMotion ? [] : [14, 8]))
                    .shadow(color: Palette.honey.opacity(0.6), radius: 10)
                    .overlay(alignment: .topLeading) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Palette.peachDeep)
                            .padding(8)
                    }
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { pulse = true }
                    }
                    .onDisappear { pulse = false }
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.8), value: tile.face)
        .contentShape(RoundedRectangle(cornerRadius: corner))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text(tile.face == .covered && !isLocked ? model.localizer["card.hint.turn"] : ""))
        .accessibilityAddTraits(tile.face == .covered ? .isButton : [])
    }

    private var accessibilityLabel: String {
        CardAccessibility.label(face: tile.face, artwork: artwork, position: position,
                                highlighted: isHighlighted, localizer: model.localizer)
    }
}

enum CardAccessibility {
    /// VoiceOver text for a card. Covered cards never reveal the animal or
    /// pose; revealed and matched cards name both.
    @MainActor
    static func label(face: TileFace, artwork: ArtworkDefinition?, position: CardPosition,
                      highlighted: Bool, localizer t: Localizer) -> String {
        let place = t("card.position", position.index + 1, position.row + 1, position.column + 1)
        var parts: [String]
        switch face {
        case .covered:
            parts = [place, t["card.faceDown"]]
        case .revealed:
            parts = [artwork.map { ArtworkText.description($0, t) } ?? t["card.unknown"], place]
        case .matched:
            parts = [t("card.matched", artwork.map { ArtworkText.description($0, t) } ?? t["card.unknown"]), place]
        }
        if highlighted { parts.append(t["card.hinted"]) }
        return parts.joined(separator: ", ")
    }
}

/// The same supplied artwork on the back of every card, so the back never
/// hints at what is underneath.
private struct CardBack: View {
    let corner: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Image(BrandGraphic.cardBack)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(Palette.lavenderDeep, lineWidth: 3)
                }
            }
            .shadow(color: Palette.shadow, radius: 6, y: 4)
    }
}

private struct CardFace: View {
    let artwork: ArtworkDefinition?
    let matched: Bool
    let corner: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(matched ? Palette.mint.opacity(0.35) : Palette.cream)
            .overlay {
                ArtworkImage(artwork: artwork)
                    .padding(8)
            }
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(matched ? Palette.mintDeep : Palette.lavender, lineWidth: matched ? 5 : (contrast == .increased ? 3 : 2)))
            .overlay(alignment: .topTrailing) {
                if matched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Palette.mintDeep)
                        .padding(6)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            .shadow(color: Palette.shadow, radius: 6, y: 4)
    }
}
