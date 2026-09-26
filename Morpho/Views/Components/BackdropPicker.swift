//
//  BackdropPicker.swift
//  Morpho
//
//  One-tap surroundings, stacked above Record on the Deck: Valley, Moon,
//  Beach, Snow, Neon City. Each sends its prompt straight to Lucy, which
//  redraws everything behind the subject; targeted casts keep applying on
//  top. Tapping the active one takes it away. One at a time.
//

import SwiftUI

struct BackdropPicker: View {
    @Environment(SessionModel.self) private var session
    @Environment(MorphoEngine.self) private var engine

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(Realm.backdrops) { backdrop in
                Toggle(isOn: binding(for: backdrop)) {
                    Label(backdrop.name, systemImage: backdrop.symbol)
                }
                .toggleStyle(BackdropToggleStyle(accent: backdrop.accent))
                .accessibilityHint("Swaps the surroundings with Lucy")
            }
        }
        .sensoryFeedback(.selection, trigger: session.activeRealm)
    }

    private func binding(for backdrop: Realm) -> Binding<Bool> {
        Binding {
            session.activeRealm == backdrop
        } set: { _ in
            engine.toggleBackdrop(backdrop)
        }
    }
}

/// The backdrop's name, then a round badge in its own gradient with its
/// symbol. The active one glows, gets a white ring, and a bolder name.
private struct BackdropToggleStyle: ToggleStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                configuration.label
                    .labelStyle(.titleOnly)
                    .font(.system(.caption, design: .rounded).weight(isOn ? .bold : .semibold))
                    .foregroundStyle(.white.opacity(isOn ? 1 : 0.85))
                    .shadow(color: .black.opacity(0.6), radius: 3)
                    // The badge below carries the name for VoiceOver.
                    .accessibilityHidden(true)

                configuration.label
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .frame(width: 46, height: 46)
                    .background {
                        Circle().fill(
                            LinearGradient(
                                colors: [accent.opacity(isOn ? 1 : 0.75), accent.mix(with: .black, by: 0.45).opacity(isOn ? 1 : 0.75)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
                    .overlay {
                        Circle().strokeBorder(.white.opacity(isOn ? 1 : 0.25), lineWidth: isOn ? 2.5 : 1)
                    }
                    .shadow(color: accent.opacity(isOn ? 0.8 : 0), radius: 10)
                    .scaleEffect(isOn ? 1.1 : 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: isOn)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
