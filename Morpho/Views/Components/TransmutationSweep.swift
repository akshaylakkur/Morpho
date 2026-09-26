//
//  TransmutationSweep.swift
//  Morpho
//
//  Every prompt application fires a 600ms iridescent wave traveling across
//  the Stage from the fold line outward, masking Lucy's first re-anchored
//  frames so the warm-up reads as intentional magic (spec §4.1). Also home
//  to the 30-second idle fold shimmer (spec §7).
//

import SwiftUI

struct TransmutationSweep: View {
    /// Increment to fire the sweep (SessionModel.sweepTrigger).
    let trigger: Int
    /// Where the wave starts, as a fraction of height (the fold line).
    let originFraction: CGFloat

    @State private var progress: CGFloat = 0
    @State private var visible = false

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let origin = height * originFraction

            ZStack {
                waveBand(at: origin - progress * origin, width: proxy.size.width)
                waveBand(at: origin + progress * (height - origin), width: proxy.size.width)
            }
            .opacity(visible ? 1 - Double(progress) * 0.7 : 0)
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) {
            progress = 0
            visible = true
            withAnimation(.easeOut(duration: Theme.sweepDuration)) {
                progress = 1
            }
            Task {
                try? await Task.sleep(for: .seconds(Theme.sweepDuration))
                visible = false
            }
        }
    }

    private func waveBand(at y: CGFloat, width: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.iridescent)
            .frame(width: width, height: 110)
            .blur(radius: 22)
            .opacity(0.75)
            .blendMode(.screen)
            .position(x: width / 2, y: y)
    }
}

/// Every 30 seconds of idle, a faint iridescent shimmer traces the fold line —
/// a reminder the hinge is alive (spec §7).
struct FoldShimmer: View {
    let foldFraction: CGFloat

    @State private var phase: CGFloat = -0.3

    var body: some View {
        GeometryReader { proxy in
            let y = proxy.size.height * foldFraction
            LinearGradient(
                colors: [.clear, .white.opacity(0.55), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1.5)
            .mask(
                Rectangle()
                    .frame(width: proxy.size.width * 0.45)
                    .position(x: proxy.size.width * phase, y: 0.75)
            )
            .position(x: proxy.size.width / 2, y: y)
        }
        .allowsHitTesting(false)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                phase = -0.3
                withAnimation(.easeInOut(duration: 1.4)) {
                    phase = 1.3
                }
            }
        }
    }
}
