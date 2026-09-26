//
//  IncantationOverlay.swift
//  Morpho
//
//  Live speech renders word-by-word along the bottom of the Stage in large
//  rounded type; when a prompt compiles and fires, the words ignite —
//  shimmer, then dissolve (spec §4.1).
//

import SwiftUI

struct IncantationOverlay: View {
    /// Live volatile transcript (what's being said right now).
    let transcript: String
    /// The compiled prompt flashed just before casting; non-nil = ignition.
    let compiled: LucyPromptSpec?

    var body: some View {
        VStack(spacing: 6) {
            if let compiled {
                ignitedText(compiled)
            } else if !transcript.isEmpty {
                liveWords
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Theme.chipSpring, value: transcript)
        .animation(Theme.chipSpring, value: compiled)
    }

    /// Word-by-word appearance for the live transcript.
    private var liveWords: some View {
        let words = transcript.split(separator: " ").suffix(12)
        return Text(words.joined(separator: " "))
            .font(.system(.title2, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .contentTransition(.numericText())
            .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
            .padding(.horizontal, 24)
            .transition(.opacity)
    }

    /// The compiled Lucy prompt, shimmering as it fires.
    private func ignitedText(_ spec: LucyPromptSpec) -> some View {
        VStack(spacing: 8) {
            Label(spec.editType.displayName, systemImage: "wand.and.stars")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)

            Text(spec.prompt)
                .font(.system(.callout, weight: .medium))
                .foregroundStyle(Theme.iridescent)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .shadow(color: .white.opacity(0.35), radius: 6)
                .padding(.horizontal, 28)
        }
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.96)),
                removal: .opacity.combined(with: .scale(scale: 1.08)).combined(with: .blurDissolve)
            )
        )
    }
}

private extension AnyTransition {
    /// A dissolve with blur that reads as the words burning off.
    static var blurDissolve: AnyTransition {
        .modifier(active: BlurModifier(radius: 10), identity: BlurModifier(radius: 0))
    }
}

private struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

#Preview("Live words") {
    ZStack {
        Color.black
        IncantationOverlay(transcript: "put me in a thunderstorm", compiled: nil)
    }
}

#Preview("Ignited") {
    ZStack {
        Color.black
        IncantationOverlay(
            transcript: "",
            compiled: Realm.realm(withID: "thunderstorm")?.promptSpec
        )
    }
}
