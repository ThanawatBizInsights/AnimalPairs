import SwiftUI

/// Image-set names of the supplied interface graphics (Assets.xcassets/UI),
/// built by Tools/artwork/build_ui_graphics.py.
enum BrandGraphic {
    static let wordmark = "brand_wordmark"
    static let groupAnimals = "home_group_animals"
    static let trophy = "results_trophy"
    static let cardBack = "card_back"
    static let corners = ["decor_corner_top_left", "decor_corner_top_right",
                          "decor_corner_bottom_left", "decor_corner_bottom_right"]
    /// Little Penguin Studio promo: the mascot waving beside animal cards (Parents banner).
    static let promoPenguinCards = "promo_penguin_cards"

    /// Little Penguin Studio mascot poses. The mascot is the studio's penguin,
    /// not Pebble: Pebble's card artwork is separate and unchanged.
    enum Mascot: String, CaseIterable {
        case wave = "mascot_wave"        // grown-ups gate (welcome)
        case star = "mascot_star"        // results (reward)
        case peek = "mascot_peek"        // Parents → Support (help)
        case reading = "mascot_reading"  // Parents → Privacy (parent information)
    }

    /// Clay stickers cut from the studio sticker sheet. Decorative only, and
    /// never placed on the game board or over cards, text or buttons.
    enum Sticker: String, CaseIterable {
        case star = "sticker_star", heart = "sticker_heart", flower = "sticker_flower"
        case sparkles = "sticker_sparkles", confetti = "sticker_confetti", rainbow = "sticker_rainbow"
        case bubbles = "sticker_bubbles", cloudLilac = "sticker_cloud_lilac"
    }

    static var all: [String] {
        [wordmark, groupAnimals, trophy, cardBack, promoPenguinCards] + corners
            + Mascot.allCases.map(\.rawValue) + Sticker.allCases.map(\.rawValue)
    }
}

/// The Little Penguin Studio mascot in one of its poses. Purely decorative:
/// hidden from VoiceOver and never tappable. The optional gentle bob is off
/// when Reduce Motion is on.
struct MascotArt: View {
    let pose: BrandGraphic.Mascot
    var bob = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var raised = false

    var body: some View {
        let moving = bob && !reduceMotion
        Image(pose.rawValue)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .offset(y: moving && raised ? -6 : 0)
            .animation(moving ? .easeInOut(duration: 1.6).repeatForever(autoreverses: true) : nil, value: raised)
            .onAppear { raised = moving }
            .onChange(of: reduceMotion) { _, reduce in raised = bob && !reduce }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// One clay sticker. Purely decorative: hidden from VoiceOver, never tappable.
struct StickerArt: View {
    let sticker: BrandGraphic.Sticker

    var body: some View {
        Image(sticker.rawValue)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The "Animal Pairs" wordmark; VoiceOver reads the app name as a heading.
struct Wordmark: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Image(BrandGraphic.wordmark)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .accessibilityLabel(Text(model.localizer["app.title"]))
            .accessibilityAddTraits(.isHeader)
    }
}

/// Trophy badge with a short localized message on its ribbon.
struct TrophyBadge: View {
    let ribbonText: String

    // Measured from the artwork: the flat front of the ribbon.
    private let ribbonCenterY: CGFloat = 0.865
    private let ribbonWidth: CGFloat = 0.42
    private let ribbonHeight: CGFloat = 0.11

    var body: some View {
        Image(BrandGraphic.trophy)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .overlay {
                GeometryReader { proxy in
                    Text(ribbonText)
                        .font(.system(size: proxy.size.height * 0.075, weight: .heavy, design: .rounded))
                        .foregroundStyle(Palette.brown)
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .frame(width: proxy.size.width * ribbonWidth, height: proxy.size.height * ribbonHeight)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * ribbonCenterY)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(ribbonText))
    }
}

/// Soft floral accents pinned to the four corners. Purely decorative; never
/// used on the game board so the cards stay clear.
struct FloralCorners: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(max(min(proxy.size.width, proxy.size.height) * 0.28, 110), 300)
            ZStack {
                corner(BrandGraphic.corners[0], side: side, alignment: .topLeading)
                corner(BrandGraphic.corners[1], side: side, alignment: .topTrailing)
                corner(BrandGraphic.corners[2], side: side, alignment: .bottomLeading)
                corner(BrandGraphic.corners[3], side: side, alignment: .bottomTrailing)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func corner(_ name: String, side: CGFloat, alignment: Alignment) -> some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: side, maxHeight: side)
            .opacity(0.9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}
