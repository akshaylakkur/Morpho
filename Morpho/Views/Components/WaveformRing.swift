//
//  WaveformRing.swift
//  Morpho
//
//  The Incant button's live waveform ring: mic amplitude rendered as a soft
//  radial equalizer (spec §4.2, §7).
//

import SwiftUI

struct WaveformRing: View {
    /// 0…1 smoothed mic amplitude.
    let amplitude: Float
    let isListening: Bool

    private let barCount = 28

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isListening)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let innerRadius = min(size.width, size.height) * 0.36
                let level = CGFloat(amplitude)

                for index in 0..<barCount {
                    let angle = (Double(index) / Double(barCount)) * 2 * .pi - .pi / 2
                    // Each bar gets its own phase so the ring undulates.
                    let wobble = 0.5 + 0.5 * sin(time * 7 + Double(index) * 1.31)
                    let length = 3 + (isListening ? level * 22 * CGFloat(wobble) + 2 : 0)

                    let inner = CGPoint(
                        x: center.x + cos(angle) * innerRadius,
                        y: center.y + sin(angle) * innerRadius
                    )
                    let outer = CGPoint(
                        x: center.x + cos(angle) * (innerRadius + length),
                        y: center.y + sin(angle) * (innerRadius + length)
                    )
                    var path = Path()
                    path.move(to: inner)
                    path.addLine(to: outer)
                    canvas.stroke(
                        path,
                        with: .color(.white.opacity(isListening ? 0.9 : 0.35)),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    ZStack {
        Color.black
        WaveformRing(amplitude: 0.6, isListening: true)
            .frame(width: 110, height: 110)
    }
}
