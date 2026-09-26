//
//  RecordButton.swift
//  Morpho
//
//  Record control: a shutter ring draws itself around the button on start;
//  stopping tucks the clip toward the Spellbook (spec §7).
//

import SwiftUI

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Shutter ring that draws itself clockwise on record start.
                Circle()
                    .trim(from: 0, to: isRecording ? 1 : 0)
                    .stroke(.red, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 58, height: 58)
                    .animation(.easeOut(duration: 0.45), value: isRecording)

                Circle()
                    .stroke(.white.opacity(0.7), lineWidth: 2)
                    .frame(width: 58, height: 58)
                    .opacity(isRecording ? 0 : 1)

                // Dot morphs into a rounded square while recording.
                RoundedRectangle(cornerRadius: isRecording ? 6 : 22)
                    .fill(.red)
                    .frame(
                        width: isRecording ? 26 : 44,
                        height: isRecording ? 26 : 44
                    )
                    .animation(Theme.chipSpring, value: isRecording)
            }
            .padding(6)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

#Preview(traits: .sizeThatFitsLayout) {
    HStack(spacing: 20) {
        RecordButton(isRecording: false) {}
        RecordButton(isRecording: true) {}
    }
    .padding()
    .background(Color.black)
}
