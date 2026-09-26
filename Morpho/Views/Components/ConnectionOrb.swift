//
//  ConnectionOrb.swift
//  Morpho
//
//  Stage state chrome (spec §4.1): breathing teal when connected, pulsing
//  amber while generating, heartbeat red while reconnecting — plus the
//  session timer chip shown while recording.
//

import SwiftUI

struct ConnectionOrb: View {
    let phase: ConnectionPhase

    @State private var breathe = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(phase.orbColor)
                .frame(width: 12, height: 12)
                .scaleEffect(breathe ? 1.0 : scaleFloor)
                .opacity(breathe ? 1.0 : 0.55)
                .shadow(color: phase.orbColor.opacity(0.8), radius: breathe ? 8 : 3)
                .animation(pulseAnimation, value: breathe)

            Text(phase.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .onAppear { breathe = true }
        .accessibilityLabel("Connection status: \(phase.label)")
    }

    private var scaleFloor: CGFloat {
        phase == .reconnecting ? 0.55 : 0.8
    }

    private var pulseAnimation: Animation {
        switch phase {
        case .connected: .easeInOut(duration: 1.8).repeatForever(autoreverses: true)
        case .generating, .connecting: .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
        case .reconnecting: .easeInOut(duration: 0.35).repeatForever(autoreverses: true)
        case .disconnected: .default
        }
    }
}

/// Elapsed-time chip shown beside the orb while recording.
struct SessionTimerChip: View {
    let startedAt: Date
    var font: Font = .subheadline.weight(.semibold)

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince(startedAt))
            // Camera-app style: white HH:MM:SS on a red rounded rectangle.
            Text(String(format: "%02d:%02d:%02d", elapsed / 3600, elapsed / 60 % 60, elapsed % 60))
                .font(font.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.red, in: .rect(cornerRadius: 6))
        }
        .accessibilityLabel("Recording")
    }
}

#Preview("Orb states", traits: .sizeThatFitsLayout) {
    VStack(spacing: 12) {
        ConnectionOrb(phase: .connected)
        ConnectionOrb(phase: .generating)
        ConnectionOrb(phase: .reconnecting)
        SessionTimerChip(startedAt: .now.addingTimeInterval(-83))
    }
    .padding()
    .background(Color.black)
}
