import AnimalPairsCore
import SwiftUI

/// Home screen: the ten friends as separate transparent PNG layers around Iris,
/// the native Animal Pairs wordmark, a large Play button and the top controls.
/// Layout comes from Resources/HomeLayout.json ("wide" for iPad landscape,
/// "tall" for iPhone and iPad portrait). Every animal has its own staggered,
/// feet-anchored wobble; animation stops when the screen is hidden or the app
/// is inactive, and Reduce Motion shows a still layout.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    private let spec = HomeLayoutSpec.shared

    private var animating: Bool { isVisible && !reduceMotion && scenePhase == .active }

    var body: some View {
        ZStack {
            if let spec {
                HomeBackdrop(spec: spec, animating: animating)
                GeometryReader { proxy in
                    if let layout = spec.layout(for: proxy.size) {
                        let geometry = HomeGeometry(size: proxy.size, layout: layout, spec: spec)
                        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animating)) { context in
                            HomeStage(geometry: geometry, spec: spec,
                                      time: animating ? context.date.timeIntervalSinceReferenceDate : nil)
                        }
                    }
                }
            } else {
                // Layout file missing: a plain, fully working fallback.
                VStack(spacing: 24) {
                    Wordmark().frame(maxWidth: 520, maxHeight: 140)
                    PlayButton(size: CGSize(width: 260, height: 84), pulse: 1)
                }
            }
            HomeTopBar(spec: spec)
            if let error = model.contentError {
                Text(model.localizer("home.contentError", error))
                    .font(.rounded(.footnote))
                    .padding()
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}

/// Animals, title and Play button, positioned in safe-area coordinates.
private struct HomeStage: View {
    let geometry: HomeGeometry
    let spec: HomeLayoutSpec
    /// nil = still (Reduce Motion, hidden or inactive).
    let time: TimeInterval?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The animal giving a little hop after being tapped.
    @State private var hopping: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(geometry.drawOrder, id: \.self) { id in
                if let frame = geometry.characterFrame(id) {
                    let wobble = time.flatMap { t in spec.motion[id].map { Wobble.at(time: t, motion: $0) } } ?? .still
                    Image("home_\(id)")
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)   // never stretched
                        .frame(height: frame.height)
                        .scaleEffect(wobble.scale * (hopping == id ? 1.06 : 1), anchor: .bottom)
                        .rotationEffect(.degrees(wobble.rotation), anchor: .bottom)
                        .offset(y: -wobble.rise)
                        // A tap gives a little hop. Neither taps nor the wobble make
                        // a sound: animal clips belong to confirmed matches only.
                        .contentShape(Rectangle())
                        .onTapGesture { hop(id) }
                        .accessibilityHidden(true)
                        .position(frame.center)
                }
            }

            Wordmark()
                .frame(width: geometry.titleSize.width, height: geometry.titleSize.height)
                .position(geometry.titleCenter)

            PlayButton(size: geometry.playSize, pulse: pulse)
                .position(geometry.playCenter)
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }

    private func hop(_ id: String) {
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) { hopping = id }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            if hopping == id { withAnimation(.easeOut(duration: 0.2)) { hopping = nil } }
        }
    }

    private var pulse: CGFloat {
        guard let time else { return 1 }
        let p = spec.playPulse
        return 1 + p.scale * CGFloat((1 + sin(2 * Double.pi * time / p.period)) / 2)
    }
}

/// The big Play button (starts the existing "choose a board" flow).
private struct PlayButton: View {
    let size: CGSize
    let pulse: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.localizer
        Button {
            model.goToSetup()
        } label: {
            Label(t["home.play"], systemImage: "pawprint.fill")
                .font(.rounded(.largeTitle, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(Palette.brown)
                .padding(.horizontal, 24)
                .frame(width: size.width, height: size.height)
                .background {
                    Capsule()
                        .fill(Palette.peach)
                        .overlay(Capsule().strokeBorder(Palette.peachDeep, lineWidth: 3))
                        .shadow(color: Palette.shadow, radius: 8, y: 5)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .scaleEffect(pulse)
        .accessibilityLabel(Text(t["home.play"]))
        .accessibilityHint(Text(t["home.play.hint"]))
    }
}

/// Sound and Settings in the top-right corner — always above the stage.
private struct HomeTopBar: View {
    let spec: HomeLayoutSpec?
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.localizer
        let bar = spec?.topBar
        let soundOn = model.settings.soundEnabled
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            RoundIconButton(systemImage: soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                            label: soundOn ? t["board.sound.on"] : t["board.sound.off"]) {
                model.setSoundEnabled(!soundOn)
            }
            .accessibilityHint(Text(t["board.sound.hint"]))
            RoundIconButton(systemImage: "gearshape.fill", label: t["home.settings"]) {
                model.openParentGate()
            }
            .accessibilityHint(Text(t["home.parents.hint"]))
        }
        .padding(.horizontal, bar?.padding ?? 16)
        .frame(height: bar?.height ?? 76)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Warm cream background with soft lavender, peach and butter-yellow playground
/// details. Decor uses full-screen fractions and may extend under the notch
/// and home indicator; nothing interactive lives here.
private struct HomeBackdrop: View {
    let spec: HomeLayoutSpec
    let animating: Bool

    var body: some View {
        GeometryReader { proxy in
            let full = proxy.size
            if let layout = spec.layout(for: full) {
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !animating)) { context in
                    let t = animating ? context.date.timeIntervalSinceReferenceDate : 0
                    ZStack(alignment: .topLeading) {
                        LinearGradient(colors: [spec.color("cream"), spec.color("creamDeep")],
                                       startPoint: .top, endPoint: .bottom)
                        ForEach(Array(layout.decor.enumerated()), id: \.offset) { index, item in
                            DecorItem(item: item, spec: spec, full: full,
                                      time: animating ? t : nil, seed: Double(index))
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct DecorItem: View {
    let item: HomeLayoutSpec.Decor
    let spec: HomeLayoutSpec
    let full: CGSize
    let time: TimeInterval?
    let seed: Double

    private var unit: CGFloat { min(full.width, full.height) }

    private func wave(_ period: Double, _ offset: Double = 0) -> Double {
        guard let time else { return 0 }
        return sin(2 * Double.pi * (time / period) + seed * 1.7 + offset)
    }

    var body: some View {
        switch item.kind {
        case "hill":
            Ellipse()
                .fill(spec.color(item.color, opacity: 0.78))
                .frame(width: (item.w ?? 0) * full.width, height: (item.h ?? 0) * full.height)
                .position(x: (item.cx ?? 0) * full.width, y: (item.cy ?? 0) * full.height)
        case "ground":
            Rectangle()
                .fill(spec.color(item.color))
                .frame(width: full.width, height: full.height * (1 - (item.top ?? 1)))
                .position(x: full.width / 2, y: full.height * (1 + (item.top ?? 1)) / 2)
        case "cloud":
            let s = (item.size ?? 0) * unit
            Cloud()
                .fill(spec.color(item.color, opacity: 0.9))
                .frame(width: s * 1.6, height: s * 1.1)
                .position(x: (item.cx ?? 0) * full.width, y: (item.cy ?? 0) * full.height)
                .offset(x: (item.drift ?? 0) * wave(item.period ?? 24))
        case "bunting":
            Bunting(item: item, spec: spec, full: full, unit: unit)
        case "swing":
            Swing(item: item, spec: spec, full: full)
        case "flower":
            let s = (item.size ?? 0) * unit
            Flower(color: spec.color(item.color, opacity: 0.86), centre: spec.color("butter"))
                .frame(width: s * 1.5, height: s * 1.5)
                .rotationEffect(.degrees(5 * wave(6)))
                .position(x: (item.cx ?? 0) * full.width, y: (item.cy ?? 0) * full.height)
        case "sparkle":
            let s = (item.size ?? 0) * unit
            Sparkle()
                .fill(spec.color(item.color, opacity: 0.86))
                .frame(width: s, height: s)
                .opacity(time == nil ? 1 : 0.55 + 0.45 * wave(3.2))
                .position(x: (item.cx ?? 0) * full.width, y: (item.cy ?? 0) * full.height)
                .offset(y: 3 * wave(5, 1))
        default:
            EmptyView()
        }
    }
}

private struct Cloud: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        for (x, y, r) in [(0.28, 0.6, 0.26), (0.5, 0.42, 0.34), (0.74, 0.58, 0.25), (0.52, 0.68, 0.27)] {
            path.addEllipse(in: CGRect(x: rect.minX + w * (x - r), y: rect.minY + h * y - w * r,
                                       width: w * r * 2, height: w * r * 2))
        }
        return path
    }
}

private struct Sparkle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY), outer = min(rect.width, rect.height) / 2
        for k in 0..<8 {
            let r = k.isMultiple(of: 2) ? outer : outer / 3.5
            let a = -Double.pi / 2 + Double(k) * Double.pi / 4
            let p = CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r)
            k == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }
}

private struct Flower: View {
    let color: Color
    let centre: Color
    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            ZStack {
                ForEach(0..<5, id: \.self) { k in
                    Circle().fill(color).frame(width: s * 0.4, height: s * 0.4)
                        .offset(x: s * 0.28 * CGFloat(cos(Double(k) * 2 * .pi / 5)),
                                y: s * 0.28 * CGFloat(sin(Double(k) * 2 * .pi / 5)))
                }
                Circle().fill(centre).frame(width: s * 0.27, height: s * 0.27)
            }
            .frame(width: s, height: s)
        }
    }
}

private struct Bunting: View {
    let item: HomeLayoutSpec.Decor
    let spec: HomeLayoutSpec
    let full: CGSize
    let unit: CGFloat

    private func point(_ t: CGFloat) -> CGPoint {
        let x1 = (item.x1 ?? 0) * full.width, x2 = (item.x2 ?? 0) * full.width
        let y1 = (item.y1 ?? 0) * full.height, y2 = (item.y2 ?? 0) * full.height
        let sag = (item.sag ?? 0) * full.height
        return CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t + sag * CGFloat(sin(Double.pi * Double(t))))
    }

    var body: some View {
        let flags = item.flags ?? 0
        let colors = item.colors ?? []
        ZStack {
            Path { path in
                path.move(to: point(0))
                for k in 1...40 { path.addLine(to: point(CGFloat(k) / 40)) }
            }
            .stroke(Color(red: 0.70, green: 0.60, blue: 0.53).opacity(0.7), lineWidth: 2)
            ForEach(0..<flags, id: \.self) { k in
                let p = point((CGFloat(k) + 0.5) / CGFloat(max(flags, 1)))
                let fw = unit * 0.022, fh = unit * 0.034
                Path { path in
                    path.move(to: CGPoint(x: p.x - fw, y: p.y))
                    path.addLine(to: CGPoint(x: p.x + fw, y: p.y))
                    path.addLine(to: CGPoint(x: p.x, y: p.y + fh))
                    path.closeSubpath()
                }
                .fill(spec.color(colors.isEmpty ? nil : colors[k % colors.count], opacity: 0.82))
            }
        }
    }
}

private struct Swing: View {
    let item: HomeLayoutSpec.Decor
    let spec: HomeLayoutSpec
    let full: CGSize

    var body: some View {
        let h = (item.height ?? 0) * full.height
        let w = h * 0.9
        let cx = (item.cx ?? 0) * full.width, bottom = (item.bottom ?? 0) * full.height
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: cx - w / 2, y: bottom))
                path.addLine(to: CGPoint(x: cx - w / 2.6, y: bottom - h))
                path.addLine(to: CGPoint(x: cx + w / 2.6, y: bottom - h))
                path.addLine(to: CGPoint(x: cx + w / 2, y: bottom))
            }
            .stroke(spec.color(item.frame, opacity: 0.86), style: StrokeStyle(lineWidth: h * 0.05, lineCap: .round, lineJoin: .round))
            Path { path in
                for dx in [-w / 8, w / 8] {
                    path.move(to: CGPoint(x: cx + dx, y: bottom - h))
                    path.addLine(to: CGPoint(x: cx + dx, y: bottom - h * 0.3))
                }
            }
            .stroke(Color(red: 0.70, green: 0.60, blue: 0.53).opacity(0.6), lineWidth: 1)
            RoundedRectangle(cornerRadius: 3)
                .fill(spec.color(item.seat, opacity: 0.9))
                .frame(width: w / 3, height: h * 0.07)
                .position(x: cx, y: bottom - h * 0.285)
        }
    }
}
