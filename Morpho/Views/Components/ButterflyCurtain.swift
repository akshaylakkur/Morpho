//
//  ButterflyCurtain.swift
//  Morpho
//
//  The Stage's resting state (spec §7): the Morpho butterfly unfolds onto a
//  dark backdrop — mirroring the device — and breathes there until the first
//  Record. Then the wings beat, fly off to the screen's edges, and an iris
//  opens from the center onto the live feed, like an aperture. When the feed
//  goes quiet the same move runs in reverse: the iris closes and the wings
//  come home, so the Stage never just freezes.
//

import SwiftUI

struct ButterflyCurtain: View {
    let phase: StagePhase
    /// Smaller mark for Scout Mode's outer display.
    var compact = false
    /// Shown under the resting butterfly (e.g. "Camera Not Connected").
    var caption: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var wingSpread: Double = 84   // degrees each wing folds in; 0 = fully open
    @State private var flutter: Double = 0       // beat, added to the spread
    @State private var hover: CGFloat = 0
    @State private var flight: CGFloat = 0       // 0 = resting, 1 = gone past the edges
    @State private var iris: CGFloat = 0         // 0 = closed backdrop, 1 = fully open

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let wingSize = compact ? CGSize(width: 54, height: 88) : CGSize(width: 84, height: 136)
            let travel = size.width / 2 + wingSize.width * 1.5

            ZStack {
                IrisShape(progress: iris)
                    .fill(Theme.stageBackground, style: FillStyle(eoFill: true))

                HStack(spacing: 2) {
                    wing(mirrored: false, size: wingSize)
                        .rotation3DEffect(
                            .degrees(wingSpread + flutter),
                            axis: (x: 0, y: 1, z: 0),
                            anchor: .trailing,
                            perspective: 0.4
                        )
                        .offset(x: -flight * travel)
                    wing(mirrored: true, size: wingSize)
                        .rotation3DEffect(
                            .degrees(-(wingSpread + flutter)),
                            axis: (x: 0, y: 1, z: 0),
                            anchor: .leading,
                            perspective: 0.4
                        )
                        .offset(x: flight * travel)
                }
                .offset(y: hover - flight * size.height * 0.16)
                .scaleEffect(1 + flight * 0.3)
                .opacity(1 - Double(flight))
                .position(x: size.width / 2, y: size.height / 2)

                if let caption {
                    Text(caption)
                        .font(.system(compact ? .footnote : .subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .position(x: size.width / 2, y: size.height / 2 + wingSize.height * 0.85)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: caption)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption.map { "Morpho. \($0)" } ?? "Morpho")
        .accessibilityHint("Press Record to open the camera")
        .onAppear(perform: settle)
        .onChange(of: phase) {
            switch phase {
            case .opening: flyAway()
            case .closing: flyHome()
            case .curtain: rest()
            case .live: break
            }
        }
    }

    private func wing(mirrored: Bool, size: CGSize) -> some View {
        ButterflyWing()
            .fill(Theme.iridescent)
            .frame(width: size.width, height: size.height)
            .scaleEffect(x: mirrored ? -1 : 1)
            .shadow(color: .purple.opacity(0.5), radius: 24)
    }

    // MARK: Motion

    /// First appearance: pick up wherever the Stage already is.
    private func settle() {
        switch phase {
        case .curtain, .live:
            // Launch moment: the wings open like the device does.
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                wingSpread = 0
            }
            rest()
        case .opening:
            wingSpread = 0
            flight = 1
            iris = 1
        case .closing:
            // Re-created mid-stream (a posture change): start beyond the edges and come home.
            wingSpread = 0
            flight = 1
            iris = 1
            flyHome()
        }
    }

    /// A slow beat and hover while the butterfly holds the Stage.
    private func rest() {
        guard !reduceMotion else {
            flutter = 0
            hover = 0
            return
        }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            flutter = 12
        }
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
            hover = -8
        }
    }

    /// The reveal: a quick beat, then off to the edges while the iris opens.
    private func flyAway() {
        if !reduceMotion {
            withAnimation(.easeInOut(duration: 0.14).repeatForever(autoreverses: true)) {
                flutter = 42
            }
        }
        withAnimation(.easeIn(duration: 0.8).delay(0.4)) {
            flight = 1
        }
        withAnimation(.easeInOut(duration: 0.9).delay(0.3)) {
            iris = 1
        }
    }

    /// The inverse: the iris closes and the wings come home from the edges.
    private func flyHome() {
        if !reduceMotion {
            withAnimation(.easeInOut(duration: 0.14).repeatForever(autoreverses: true)) {
                flutter = 42
            }
        }
        withAnimation(.easeInOut(duration: 0.9)) {
            iris = 0
        }
        withAnimation(.easeOut(duration: 0.85).delay(0.25)) {
            flight = 0
        }
    }
}

/// A full rect with a circular hole that grows from the center (even-odd fill).
struct IrisShape: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let diameter = hypot(rect.width, rect.height) * max(0, progress)
        guard diameter > 0 else { return path }
        path.addEllipse(in: CGRect(
            x: rect.midX - diameter / 2,
            y: rect.midY - diameter / 2,
            width: diameter,
            height: diameter
        ))
        return path
    }
}

/// One butterfly wing: a large upper lobe and smaller lower lobe.
private struct ButterflyWing: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        // Upper lobe.
        path.move(to: CGPoint(x: w, y: h * 0.52))
        path.addCurve(
            to: CGPoint(x: w * 0.12, y: h * 0.06),
            control1: CGPoint(x: w * 0.86, y: h * 0.30),
            control2: CGPoint(x: w * 0.52, y: h * 0.02)
        )
        path.addCurve(
            to: CGPoint(x: w, y: h * 0.46),
            control1: CGPoint(x: -w * 0.18, y: h * 0.12),
            control2: CGPoint(x: w * 0.32, y: h * 0.50)
        )
        path.closeSubpath()

        // Lower lobe.
        path.move(to: CGPoint(x: w, y: h * 0.55))
        path.addCurve(
            to: CGPoint(x: w * 0.30, y: h * 0.97),
            control1: CGPoint(x: w * 0.42, y: h * 0.58),
            control2: CGPoint(x: w * 0.06, y: h * 0.78)
        )
        path.addCurve(
            to: CGPoint(x: w, y: h * 0.62),
            control1: CGPoint(x: w * 0.62, y: h * 1.02),
            control2: CGPoint(x: w * 0.88, y: h * 0.80)
        )
        path.closeSubpath()
        return path
    }
}
