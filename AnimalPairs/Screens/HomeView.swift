import AnimalPairsCore
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.localizer
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                LanguageMenu()
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
                Text(t["app.title"])
                    .font(.rounded(.largeTitle, weight: .heavy))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(t["home.subtitle"])
                    .font(.rounded(.title3, weight: .medium))
                    .foregroundStyle(Palette.brownSoft)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            AnimalParade(characters: model.catalog.manifest.characters, catalog: model.catalog)
                .frame(maxHeight: 300)
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
    }
}

/// Gently bobbing row of the ten friends.
struct AnimalParade: View {
    let characters: [CharacterDefinition]
    let catalog: ContentCatalog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bob = false

    var body: some View {
        GeometryReader { proxy in
            let count = max(characters.count, 1)
            let perRow = proxy.size.width > 700 ? count : (count + 1) / 2
            let side = min(proxy.size.width / CGFloat(perRow) - 8, perRow == count ? proxy.size.height : proxy.size.height / 2 - 8)
            let rows = stride(from: 0, to: characters.count, by: perRow).map { Array(characters[$0..<min($0 + perRow, characters.count)]) }
            VStack(spacing: 4) {
                ForEach(rows.indices, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(Array(rows[row].enumerated()), id: \.element.id) { index, character in
                            let art = catalog.manifest.artwork(AssetID(rawValue: "\(character.id.rawValue).\(character.defaultPoseID.rawValue)"))
                            ArtworkImage(artwork: art)
                                .frame(width: max(side, 40), height: max(side, 40))
                                .offset(y: bob && !reduceMotion ? (index % 2 == 0 ? -6 : 6) : 0)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { bob = true }
        }
    }
}

struct LanguageMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.localizer
        Menu {
            ForEach(AppLanguage.allCases) { option in
                Button {
                    model.setLanguage(option)
                } label: {
                    if option == model.settings.language {
                        Label(t.displayName(for: option), systemImage: "checkmark")
                    } else {
                        Text(t.displayName(for: option))
                    }
                }
            }
        } label: {
            Label(t["home.language"], systemImage: "globe")
                .font(.rounded(.headline, weight: .semibold))
                .padding(.horizontal, 18)
                .frame(minHeight: Metrics.touchTarget)
                .background(Capsule().fill(Palette.cream).shadow(color: Palette.shadow, radius: 4, y: 2))
        }
        .accessibilityLabel(Text(t["home.language"]))
        .accessibilityValue(Text(t.displayName(for: model.settings.language)))
    }
}
