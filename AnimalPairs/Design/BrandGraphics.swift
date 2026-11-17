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
    static var all: [String] { [wordmark, groupAnimals, trophy, cardBack] + corners }
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
