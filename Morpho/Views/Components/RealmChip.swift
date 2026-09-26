//
//  RealmChip.swift
//  Morpho
//
//  A Realm preset chip (spec §4.2): looping preview thumbnail when bundled,
//  gradient fallback otherwise. The active chip glows and gently undulates;
//  switching does a tiny origami flip. Long-press reveals the full prompt.
//

import AVKit
import SwiftUI

struct RealmChip: View {
    let realm: Realm
    let isActive: Bool
    let action: () -> Void

    @State private var showPrompt = false
    @State private var undulate = false
    @State private var flip: Double = 0

    var body: some View {
        Button(action: cast) {
            VStack(spacing: 5) {
                thumbnail
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(
                                isActive ? AnyShapeStyle(Theme.iridescent) : AnyShapeStyle(.white.opacity(0.15)),
                                lineWidth: isActive ? 2.5 : 1
                            )
                    )
                    .shadow(color: isActive ? realm.accent.opacity(0.75) : .clear, radius: 10)
                    .scaleEffect(isActive && undulate ? 1.05 : 1.0)
                    .rotation3DEffect(.degrees(flip), axis: (x: 0, y: 1, z: 0))

                Text(realm.name)
                    .font(.caption2.weight(isActive ? .bold : .medium))
                    .foregroundStyle(isActive ? .white : .white.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        // Transparency for judges: the exact prompt behind the chip.
        .onLongPressGesture(minimumDuration: 0.4) {
            showPrompt = true
        }
        .popover(isPresented: $showPrompt) {
            VStack(alignment: .leading, spacing: 8) {
                Label(realm.name, systemImage: realm.symbol)
                    .font(.headline)
                Text(realm.prompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(idealWidth: 320)
            .presentationCompactAdaptation(.popover)
        }
        .onChange(of: isActive) {
            if isActive {
                // Origami flip on activation (spec §7).
                flip = -90
                withAnimation(Theme.chipSpring) { flip = 0 }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    undulate = true
                }
            } else {
                undulate = false
            }
        }
        .accessibilityLabel("\(realm.name) realm")
        .accessibilityHint(isActive ? "Clears the realm" : "Casts this realm")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private func cast() {
        action()
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = Bundle.main.url(forResource: realm.previewAssetName, withExtension: "mp4") {
            LoopingPreview(url: url)
        } else {
            // Pre-event fallback: accent gradient + symbol.
            ZStack {
                LinearGradient(
                    colors: [realm.accent.opacity(0.85), realm.accent.opacity(0.35)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: realm.symbol)
                    .font(.title2)
                    .foregroundStyle(.white)
            }
        }
    }
}

/// Muted, looping, non-interactive video thumbnail for a Realm preview asset.
private struct LoopingPreview: View {
    let url: URL

    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        VideoPlayer(player: player)
            .disabled(true)
            .onAppear {
                let queuePlayer = AVQueuePlayer()
                queuePlayer.isMuted = true
                looper = AVPlayerLooper(player: queuePlayer, templateItem: AVPlayerItem(url: url))
                queuePlayer.play()
                player = queuePlayer
            }
            .onDisappear {
                player?.pause()
                player = nil
                looper = nil
            }
    }
}
