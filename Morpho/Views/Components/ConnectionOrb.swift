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

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince(startedAt))
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(String(format: "%d:%02d", elapsed / 60, elapsed % 60))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
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
