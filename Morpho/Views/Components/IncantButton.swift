//
//  IncantButton.swift
//  Morpho
//
//  The Incant control (spec §4.2): hold-to-talk, or tap to latch Open Mic.
//  Used by Scout Mode on the outer display.
//

import SwiftUI

struct IncantButton: View {
    @Environment(SessionModel.self) private var session
    @Environment(VoiceConductor.self) private var conductor

    var size: CGFloat = 72

    @State private var holdActive = false

    var body: some View {
        ZStack {
            WaveformRing(
                amplitude: session.micAmplitude,
                isListening: session.micMode != .idle
            )
            .frame(width: size + 34, height: size + 34)

            Image(systemName: session.micMode == .openMic ? "waveform.circle.fill" : "mic.fill")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(session.micMode == .idle ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.iridescent))
                .frame(width: size, height: size)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .frame(width: size + 34, height: size + 34)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.25)
                .onEnded { _ in
                    holdActive = true
                    conductor.beginHold()
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onEnded { _ in
                    if holdActive {
                        holdActive = false
                        conductor.endHold()
                    }
                }
        )
        .onTapGesture {
            conductor.toggleOpenMic()
        }
        .accessibilityLabel("Incant")
        .accessibilityHint("Hold to talk, tap to latch open mic")
    }
}
