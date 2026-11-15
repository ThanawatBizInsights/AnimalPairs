import AnimalPairsCore
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.localizer
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Spacer()
                Button {
                    model.openParentGate()
                } label: {
                    Label(t["home.parents"], systemImage: "lock.fill")
                        .font(.rounded(.headline, weight: .semibold))
                        .padding(.horizontal, 18)
                        .frame(minHeight: Metrics.touchTarget)
                        .background(Capsule().fill(Palette.cream).shadow(color: Palette.shadow, radius: 4, y: 2))
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(t["home.parents.hint"]))
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            Spacer(minLength: 12)

            VStack(spacing: 8) {
                Wordmark()
                    .frame(maxWidth: 560, maxHeight: 150)
                Text(t["home.subtitle"])
                    .font(.rounded(.title3, weight: .medium))
                    .foregroundStyle(Palette.brownSoft)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            GroupIllustration()
                .frame(maxWidth: 820, maxHeight: 360)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)

            VStack(spacing: 16) {
                if model.resumableRound != nil {
                    Button {
                        model.resumeSavedGame()
                    } label: {
                        Label(t["home.resume"], systemImage: "play.circle.fill")
                    }
                    .buttonStyle(PillowButtonStyle(kind: .mint))
                    .accessibilityHint(Text(t["home.resume.hint"]))
                }
                Button {
                    model.goToSetup()
                } label: {
                    Label(t["home.play"], systemImage: "pawprint.fill")
                        .frame(minWidth: 220)
                }
                .buttonStyle(PillowButtonStyle(kind: .primary))
            }

            if let error = model.contentError {
                Text(t("home.contentError", error))
                    .font(.rounded(.footnote))
                    .padding()
            }
            Spacer(minLength: 24)
        }
        .background { FloralCorners() }
    }
}
