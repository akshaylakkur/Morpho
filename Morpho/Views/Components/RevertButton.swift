//
//  RevertButton.swift
//  Morpho
//
//  "Back to Original", beside Record on the Deck: kills every edit in
//  effect and every edit in the making — backdrops, spoken casts, targeted
//  augmentations, an open mic, a prompt being composed — and closes the
//  Lucy session at once, so the Stage shows the untouched camera.
//

import SwiftUI

struct RevertButton: View {
    @Environment(SessionModel.self) private var session
    @Environment(MorphoEngine.self) private var engine
    @Environment(VoiceConductor.self) private var conductor

    @State private var reverts = 0

    var body: some View {
        Button("Back to Original", systemImage: "arrow.uturn.backward") {
            conductor.stopEverything()
            engine.revertToOriginal()
            reverts += 1
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 19, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 52, height: 52)
        .glassEffect(.regular.interactive(), in: .circle)
        .contentShape(.circle)
        .buttonStyle(.plain)
        .opacity(hasAnythingToStop ? 1 : 0.4)
        .disabled(!hasAnythingToStop)
        .animation(.easeOut(duration: 0.2), value: hasAnythingToStop)
        .sensoryFeedback(.impact(weight: .medium), trigger: reverts)
        .accessibilityHint("Removes every edit and stops Lucy, showing the original camera")
    }

    private var hasAnythingToStop: Bool {
        session.hasAnyCast
            || session.targeting.isActive
            || session.micMode != .idle
            || session.lucy.phase.isInSession
    }
}
