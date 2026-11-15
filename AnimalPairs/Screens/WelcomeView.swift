import SwiftUI

/// Shown on first launch: meet the ten friends, then go to Home.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.localizer
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 18) {
                    HStack {
                        LanguageMenu()
                        Spacer()
                    }

                    Wordmark()
                        .frame(maxWidth: 560, maxHeight: min(150, proxy.size.height * 0.16))

                    GroupIllustration()
                        .frame(maxWidth: 900, maxHeight: max(180, proxy.size.height * 0.42))

                    VStack(spacing: 10) {
                        Text(t["welcome.title"])
                            .font(.rounded(.largeTitle, weight: .bold))
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text(t["welcome.body"])
                            .font(.rounded(.title3, weight: .medium))
                            .foregroundStyle(Palette.brownSoft)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 620)
                    }

                    Button {
                        model.sounds.play(.tap)
                        model.finishWelcome()
                    } label: {
                        Label(t["welcome.start"], systemImage: "pawprint.fill")
                            .frame(minWidth: 240)
                    }
                    .buttonStyle(PillowButtonStyle(kind: .primary))
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background { FloralCorners() }
    }
}
