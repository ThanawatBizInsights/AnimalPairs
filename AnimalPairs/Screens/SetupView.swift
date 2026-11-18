import AnimalPairsCore
import SwiftUI

struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: GameMode = .classic
    @State private var board: BoardSize = .six
    @State private var lockedMessageVisible = false
    @State private var startError: String?
    @ScaledMetric(relativeTo: .title2) private var stickerSize: CGFloat = 32

    var body: some View {
        let t = model.localizer
        let policy = model.policy
        VStack(spacing: 0) {
            HStack {
                RoundIconButton(systemImage: "house.fill", label: t["common.home"]) { model.goHome() }
                Spacer()
                Text(t["setup.title"])
                    .font(.rounded(.largeTitle, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Color.clear.frame(width: Metrics.touchTarget, height: Metrics.touchTarget)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    section(t["setup.mode"], sticker: .star) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) { modeCards(policy) }
                            VStack(spacing: 16) { modeCards(policy) }
                        }
                    }

                    section(t["setup.board"], sticker: .heart) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                            ForEach(BoardSize.allCases) { size in
                                BoardOption(size: size, selected: board == size, locked: !policy.isAvailable(size),
                                            title: t("setup.cards", size.cardCount)) {
                                    select(board: size, policy: policy)
                                }
                            }
                        }
                    }

                    section(t["setup.animals"], sticker: .flower) {
                        let characters = model.catalog.playableCharacters(for: policy)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(characters, id: \.id) { character in
                                    VStack(spacing: 4) {
                                        ArtworkImage(artwork: model.catalog.manifest.artwork(
                                            AssetID(rawValue: "\(character.id.rawValue).\(character.defaultPoseID.rawValue)")))
                                            .frame(width: 84, height: 84)
                                            .background(Circle().fill(Palette.cream))
                                        Text(ArtworkText.characterName(character.id, t))
                                            .font(.rounded(.subheadline, weight: .semibold))
                                    }
                                    .accessibilityElement(children: .combine)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        let poseCount = model.catalog.playableArtworks(for: policy).count
                        Text(t("setup.artCount", poseCount))
                            .font(.rounded(.subheadline))
                            .foregroundStyle(Palette.brownSoft)
                    }

                    if lockedMessageVisible {
                        Panel {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(t["setup.locked.title"], systemImage: "lock.fill")
                                    .font(.rounded(.title3, weight: .bold))
                                Text(t["setup.locked.body"])
                                    .font(.rounded(.body))
                                Button(t["setup.locked.askGrownUp"]) { model.openParentGate() }
                                    .buttonStyle(PillowButtonStyle(kind: .secondary))
                            }
                        }
                        .transition(.opacity)
                    }

                    if let startError {
                        Text(startError).font(.rounded(.body)).foregroundStyle(Palette.brown)
                    }
                }
                .padding(24)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }

            Button {
                start()
            } label: {
                Label(t["setup.start"], systemImage: "play.fill").frame(minWidth: 220)
            }
            .buttonStyle(PillowButtonStyle(kind: .primary))
            .padding(.bottom, 20)
            .padding(.top, 8)
        }
        .onAppear {
            let last = model.settings.lastConfiguration
            mode = policy.isAvailable(last.mode) ? last.mode : .classic
            board = policy.isAvailable(last.boardSize) ? last.boardSize : .six
        }
    }

    @ViewBuilder
    private func modeCards(_ policy: ContentAccessPolicy) -> some View {
        let t = model.localizer
        ModeOption(mode: .classic, title: t["mode.classic"], detail: t["mode.classic.detail"],
                   selected: mode == .classic, locked: !policy.isAvailable(.classic),
                   artworks: (["momo.signature", "iris.signature"] as [AssetID]).compactMap { model.catalog.artwork($0) }) {
            select(mode: .classic, policy: policy)
        }
        ModeOption(mode: .exactPose, title: t["mode.exactPose"], detail: t["mode.exactPose.detail"],
                   selected: mode == .exactPose, locked: !policy.isAvailable(.exactPose),
                   artworks: (["momo.signature", "momo.play"] as [AssetID]).compactMap { model.catalog.artwork($0) }) {
            select(mode: .exactPose, policy: policy)
        }
    }

    private func section<Content: View>(_ title: String, sticker: BrandGraphic.Sticker? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                // Small decorative clay sticker beside the heading (hidden from VoiceOver).
                if let sticker {
                    StickerArt(sticker: sticker).frame(width: stickerSize, height: stickerSize)
                }
                Text(title)
                    .font(.rounded(.title2, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
            }
            content()
        }
    }

    private func select(mode newMode: GameMode, policy: ContentAccessPolicy) {
        model.audio.play(.modeSelect)
        if policy.isAvailable(newMode) {
            mode = newMode
            lockedMessageVisible = false
        } else {
            lockedMessageVisible = true
        }
    }

    private func select(board newBoard: BoardSize, policy: ContentAccessPolicy) {
        model.audio.play(.modeSelect)
        if policy.isAvailable(newBoard) {
            board = newBoard
            lockedMessageVisible = false
        } else {
            lockedMessageVisible = true
        }
    }

    private func start() {
        do {
            try model.startNewGame(GameConfiguration(mode: mode, boardSize: board))
        } catch AppModel.StartError.locked {
            lockedMessageVisible = true
        } catch {
            startError = model.localizer["setup.error.content"]
        }
    }
}

private struct ModeOption: View {
    let mode: GameMode
    let title: String
    let detail: String
    let selected: Bool
    let locked: Bool
    let artworks: [ArtworkDefinition]
    let action: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                HStack(spacing: -18) {
                    ForEach(artworks, id: \.assetID) { art in
                        ArtworkImage(artwork: art)
                            .frame(width: 76, height: 76)
                            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.cream))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.lavender, lineWidth: 2))
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(title).font(.rounded(.title3, weight: .bold))
                        if locked { Image(systemName: "lock.fill").accessibilityHidden(true) }
                    }
                    Text(detail).font(.rounded(.body)).foregroundStyle(Palette.brownSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Metrics.cornerRadius).fill(selected ? Palette.lavenderMist : Palette.cream))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius)
                .strokeBorder(selected ? Palette.lavenderDeep : Palette.lavender.opacity(0.6), lineWidth: selected ? 4 : 2))
            .opacity(locked ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(locked ? model.localizer("setup.lockedItem", title) : title))
        .accessibilityHint(Text(detail))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct BoardOption: View {
    let size: BoardSize
    let selected: Bool
    let locked: Bool
    let title: String
    let action: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                    ForEach(0..<size.rows, id: \.self) { _ in
                        GridRow {
                            ForEach(0..<size.columns, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 3).fill(Palette.lavender).frame(width: 14, height: 18)
                            }
                        }
                    }
                }
                HStack(spacing: 6) {
                    Text(title).font(.rounded(.headline, weight: .bold))
                    if locked { Image(systemName: "lock.fill").accessibilityHidden(true) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 130)
            .background(RoundedRectangle(cornerRadius: Metrics.cornerRadius).fill(selected ? Palette.lavenderMist : Palette.cream))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius)
                .strokeBorder(selected ? Palette.lavenderDeep : Palette.lavender.opacity(0.6), lineWidth: selected ? 4 : 2))
            .opacity(locked ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(locked ? model.localizer("setup.lockedItem", title) : title))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
