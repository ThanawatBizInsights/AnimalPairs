import SwiftUI

@main
struct AnimalPairsApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(\.locale, model.localizer.locale)
                .task { model.start() }
                .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            WarmBackground()
            switch model.route {
            case .welcome:
                WelcomeView().transition(.opacity)
            case .home:
                HomeView().transition(.opacity)
            case .setup:
                SetupView().transition(.opacity)
            case .game:
                if let session = model.session {
                    GameBoardView(session: session).transition(.opacity)
                }
            case .results(let summary):
                ResultsView(summary: summary).transition(.opacity)
            case .parentGate:
                ParentalGateView().transition(.opacity)
            case .parents:
                ParentsView().transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.route)
        .foregroundStyle(Palette.brown)
        .fontDesign(.rounded)
        .tint(Palette.peachDeep)
    }
}
