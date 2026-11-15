import AnimalPairsCore
import SwiftUI

/// Adult check before Parents, purchases and external links.
/// Primary input: large on-screen keypad. Accessible alternative: a standard
/// text field (works with VoiceOver, Voice Control, Switch Control and
/// hardware keyboards). Not age verification and not consent.
struct ParentalGateView: View {
    @Environment(AppModel.self) private var model
    @State private var gate: ParentalGate = {
        var generator = SystemRandomNumberGenerator()
        return ParentalGate(challenge: .random(using: &generator))
    }()
    @State private var entry = ""
    @State private var feedback: String?
    @State private var useKeyboard = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let t = model.localizer
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    RoundIconButton(systemImage: "xmark", label: t["gate.cancel"]) { model.goHome() }
                    Spacer()
                }

                Image(systemName: "person.2.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Palette.lavenderDeep)
                    .accessibilityHidden(true)
                Text(t["gate.title"])
                    .font(.rounded(.largeTitle, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text(t["gate.explanation"])
                    .font(.rounded(.body))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)

                Text(t("gate.question", numberWord(gate.challenge.lhs), numberWord(gate.challenge.rhs)))
                    .font(.rounded(.title, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 8)
                    .accessibilityAddTraits(.isHeader)

                if useKeyboard {
                    HStack(spacing: 12) {
                        TextField(t["gate.answer"], text: $entry)
                            .keyboardType(.numberPad)
                            .font(.rounded(.title, weight: .bold))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 200, minHeight: Metrics.touchTarget)
                            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.cream))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.lavenderDeep, lineWidth: 2))
                            .focused($fieldFocused)
                            .onSubmit(submit)
                        Button(t["gate.submit"], action: submit)
                            .buttonStyle(PillowButtonStyle(kind: .primary))
                    }
                    .onAppear { fieldFocused = true }
                } else {
                    Text(entry.isEmpty ? " " : entry)
                        .font(.rounded(.largeTitle, weight: .heavy))
                        .frame(minWidth: 200, minHeight: 70)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.cream))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.lavenderDeep, lineWidth: 2))
                        .accessibilityLabel(Text(t["gate.answer"]))
                        .accessibilityValue(Text(entry))
                    Keypad(entry: $entry, submit: submit)
                }

                if let feedback {
                    Text(feedback)
                        .font(.rounded(.headline))
                        .multilineTextAlignment(.center)
                }

                Button(useKeyboard ? t["gate.useKeypad"] : t["gate.useKeyboard"]) {
                    useKeyboard.toggle()
                    entry = ""
                }
                .font(.rounded(.headline))
                .frame(minHeight: 44)

                Text(t["gate.disclaimer"])
                    .font(.rounded(.footnote))
                    .foregroundStyle(Palette.brownSoft)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func numberWord(_ value: Int) -> String {
        model.localizer["number.\(value)"]
    }

    private func submit() {
        let t = model.localizer
        var generator = SystemRandomNumberGenerator()
        let result = gate.submit(entry, using: &generator)
        entry = ""
        switch result {
        case .granted:
            feedback = nil
            model.parentGatePassed()
        case .incorrect(let remaining):
            feedback = t("gate.incorrect", remaining)
        case .newChallenge:
            feedback = t["gate.newQuestion"]
        }
        if let feedback { AccessibilityNotification.Announcement(feedback).post() }
    }
}

private struct Keypad: View {
    @Binding var entry: String
    let submit: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.localizer
        let keys: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["⌫", "0", "OK"]]
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(keys, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { key in
                        Button {
                            press(key)
                        } label: {
                            Group {
                                if key == "⌫" {
                                    Image(systemName: "delete.left.fill")
                                } else if key == "OK" {
                                    Image(systemName: "checkmark")
                                } else {
                                    Text(key)
                                }
                            }
                            .font(.rounded(.title, weight: .bold))
                            .frame(width: 84, height: 72)
                            .background(RoundedRectangle(cornerRadius: 18).fill(key == "OK" ? Palette.peach : Palette.cream))
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.lavender, lineWidth: 2))
                            .contentShape(RoundedRectangle(cornerRadius: 18))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(key == "⌫" ? t["gate.delete"] : key == "OK" ? t["gate.submit"] : key))
                    }
                }
            }
        }
    }

    private func press(_ key: String) {
        switch key {
        case "⌫": if !entry.isEmpty { entry.removeLast() }
        case "OK": submit()
        default: if entry.count < 3 { entry.append(key) }
        }
    }
}
