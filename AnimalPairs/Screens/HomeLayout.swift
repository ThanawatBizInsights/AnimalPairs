import SwiftUI

/// Decoded `Resources/HomeLayout.json`. The same file drives
/// `Tools/home/home_layout.py`, which renders previews and checks that no two
/// animals (including their full wobble) touch each other, the title, the Play
/// button or the top controls, and that everything stays inside the safe area.
struct HomeLayoutSpec: Decodable {
    struct Title: Decodable { let cx, cy, widthFraction, maxHeightFraction: CGFloat }
    struct Play: Decodable { let cx, cy, width, height: CGFloat }
    struct Placement: Decodable { let cx, bottom, height: CGFloat }
    struct Motion: Decodable { let period, phase, rotation: Double; let bob, scale: CGFloat }
    struct TopBar: Decodable { let height, controlSize, padding, resumeWidth: CGFloat }
    struct Pulse: Decodable { let period: Double; let scale: CGFloat }
    struct Decor: Decodable {
        let kind: String
        let cx, cy, w, h, top, x1, y1, x2, y2, sag, size, drift, bottom, height: CGFloat?
        let period: Double?
        let color, frame, seat: String?
        let colors: [String]?
        let flags: Int?
    }
    struct Layout: Decodable {
        let title: Title
        let play: Play
        let characters: [String: Placement]
        let decor: [Decor]
    }

    let wordmarkAspect: CGFloat
    let topBar: TopBar
    let layouts: [String: Layout]
    let motion: [String: Motion]
    let playPulse: Pulse
    let colors: [String: String]

    /// The ten friends, in the order they are drawn when two rows meet.
    static let characterIDs = ["momo", "iris", "nori", "sprout", "mochi", "sunny", "maple", "clover", "rusty", "pebble"]

    static let shared: HomeLayoutSpec? = {
        guard let url = Bundle.main.url(forResource: "HomeLayout", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HomeLayoutSpec.self, from: data)
    }()

    /// "wide" when the safe area is wider than tall (iPad landscape), else "tall".
    func layout(for size: CGSize) -> Layout? {
        layouts[size.width > size.height ? "wide" : "tall"]
    }

    func color(_ name: String?, opacity: Double = 1) -> Color {
        guard let name, let hex = colors[name], let value = UInt32(hex, radix: 16) else { return .clear }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255).opacity(opacity)
    }
}

/// Pure layout maths (mirrors `Layout` in Tools/home/home_layout.py).
struct HomeGeometry {
    let size: CGSize          // safe-area size
    let layout: HomeLayoutSpec.Layout
    let spec: HomeLayoutSpec

    func characterFrame(_ id: String) -> (center: CGPoint, height: CGFloat)? {
        guard let p = layout.characters[id] else { return nil }
        let height = p.height * size.height
        return (CGPoint(x: p.cx * size.width, y: p.bottom * size.height - height / 2), height)
    }

    var titleSize: CGSize {
        let t = layout.title
        let width = min(t.widthFraction * size.width, t.maxHeightFraction * size.height * spec.wordmarkAspect)
        return CGSize(width: width, height: width / spec.wordmarkAspect)
    }

    var titleCenter: CGPoint { CGPoint(x: layout.title.cx * size.width, y: layout.title.cy * size.height) }

    var playSize: CGSize { CGSize(width: min(layout.play.width, 0.8 * size.width), height: layout.play.height) }

    var playCenter: CGPoint { CGPoint(x: layout.play.cx * size.width, y: layout.play.cy * size.height) }

    /// Back rows first, so nearer animals overlap correctly.
    var drawOrder: [String] {
        HomeLayoutSpec.characterIDs.sorted { (layout.characters[$0]?.bottom ?? 0) < (layout.characters[$1]?.bottom ?? 0) }
    }
}

/// One frame of an animal's gentle wobble. All values are zero when still.
struct Wobble: Equatable {
    var rotation: Double = 0   // degrees, about the feet
    var rise: CGFloat = 0      // points upward, never below the ground line
    var scale: CGFloat = 1     // grows from the feet

    static let still = Wobble()

    static func at(time: TimeInterval, motion m: HomeLayoutSpec.Motion) -> Wobble {
        let angle = 2 * Double.pi * (time / m.period + m.phase)
        return Wobble(rotation: m.rotation * sin(angle),
                      rise: m.bob * CGFloat((1 - cos(2 * angle)) / 2),
                      scale: 1 + m.scale * CGFloat((1 + sin(angle + .pi / 2)) / 2))
    }
}
