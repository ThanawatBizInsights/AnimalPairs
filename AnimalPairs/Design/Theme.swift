import SwiftUI

/// Warm, soft palette taken from the reference sheet. Text colours keep
/// at least 4.5:1 contrast against the backgrounds they are used on.
enum Palette {
    static let ivory = Color(red: 1.000, green: 0.973, blue: 0.925)        // #FFF8EC
    static let ivoryDeep = Color(red: 0.984, green: 0.922, blue: 0.827)    // #FBEBD3
    static let cream = Color(red: 1.000, green: 0.992, blue: 0.973)        // #FFFDF8 card face
    static let lavender = Color(red: 0.788, green: 0.722, blue: 0.910)     // #C9B8E8 card back
    static let lavenderDeep = Color(red: 0.616, green: 0.537, blue: 0.808) // #9D89CE
    static let lavenderMist = Color(red: 0.902, green: 0.871, blue: 0.965) // #E6DEF6
    static let mint = Color(red: 0.659, green: 0.878, blue: 0.773)         // #A8E0C5
    static let mintDeep = Color(red: 0.169, green: 0.522, blue: 0.369)     // #2B855E outline/check
    static let peach = Color(red: 1.000, green: 0.706, blue: 0.549)        // #FFB48C buttons
    static let peachDeep = Color(red: 0.890, green: 0.502, blue: 0.333)    // #E38055 button edge
    static let brown = Color(red: 0.290, green: 0.180, blue: 0.129)        // #4A2E21 text
    static let brownSoft = Color(red: 0.420, green: 0.282, blue: 0.212)    // #6B4836 secondary text
    static let honey = Color(red: 0.949, green: 0.702, blue: 0.239)        // #F2B33D hint glow
    static let shadow = Color(red: 0.494, green: 0.341, blue: 0.231).opacity(0.18)
}

enum Metrics {
    /// Preferred minimum touch target; never below 44.
    static let touchTarget: CGFloat = 60
    static let cornerRadius: CGFloat = 22
}

extension Font {
    static func rounded(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
}

/// Large, soft "pillow" button used throughout.
struct PillowButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, mint }
    var kind: Kind = .primary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let fill = fillColor
        let edge = edgeColor
        return configuration.label
            .font(.rounded(.title2, weight: .bold))
            .foregroundStyle(Palette.brown)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .frame(minWidth: 140, minHeight: Metrics.touchTarget)
            .background {
                Capsule()
                    .fill(fill)
                    .overlay(Capsule().strokeBorder(edge.opacity(contrast == .increased ? 1 : 0.55), lineWidth: contrast == .increased ? 3 : 2))
                    .shadow(color: Palette.shadow, radius: configuration.isPressed ? 2 : 6, y: configuration.isPressed ? 1 : 4)
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.55)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }

    private var fillColor: Color {
        switch kind {
        case .primary: Palette.peach
        case .secondary: Palette.cream
        case .mint: Palette.mint
        }
    }

    private var edgeColor: Color {
        switch kind {
        case .primary: Palette.peachDeep
        case .secondary: Palette.lavenderDeep
        case .mint: Palette.mintDeep
        }
    }
}

/// Round icon button (pause, sound, close…) that is at least 60×60.
struct RoundIconButton: View {
    let systemImage: String
    let label: String
    var tint: Color = Palette.cream
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.brown)
                .frame(width: Metrics.touchTarget, height: Metrics.touchTarget)
                .background(Circle().fill(tint).shadow(color: Palette.shadow, radius: 5, y: 3))
                .overlay(Circle().strokeBorder(Palette.lavenderDeep.opacity(0.4), lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// Soft ivory background with gentle shapes. Drawn in SwiftUI, never a bitmap.
struct WarmBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.ivory, Palette.ivoryDeep], startPoint: .top, endPoint: .bottom)
            GeometryReader { proxy in
                let size = proxy.size
                Circle().fill(Palette.lavenderMist.opacity(0.55))
                    .frame(width: size.width * 0.5).position(x: size.width * 0.05, y: size.height * 0.1)
                Circle().fill(Palette.mint.opacity(0.22))
                    .frame(width: size.width * 0.45).position(x: size.width * 0.98, y: size.height * 0.92)
                Circle().fill(Palette.peach.opacity(0.16))
                    .frame(width: size.width * 0.3).position(x: size.width * 0.92, y: size.height * 0.12)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Rounded panel used for dialogs and sections.
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(Palette.cream)
                    .shadow(color: Palette.shadow, radius: 16, y: 8)
            )
    }
}
