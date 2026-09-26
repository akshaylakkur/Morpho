//
//  RiftSlider.swift
//  Morpho
//
//  The draggable wipe comparing original ↔ transformed feeds in real time
//  (spec §4.1). Fold-aware: in Director Mode it snaps to the fold line so
//  each fold region shows one reality. 1.0 = fully transformed.
//

import SwiftUI

struct RiftSlider: View {
    @Binding var fraction: CGFloat
    /// The axis the wipe *moves along*: .vertical in Director (horizontal
    /// divider sliding up/down), .horizontal in Canvas/Scout.
    let axis: Axis
    /// Normalized snap target (the fold line), when the posture provides one.
    let snapFraction: CGFloat?

    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            dividerHandle(in: size)
                .gesture(dragGesture(in: size))
        }
        .accessibilityLabel("Reality rift slider")
        .accessibilityValue("\(Int(fraction * 100)) percent transformed")
    }

    // MARK: Divider

    private func dividerHandle(in size: CGSize) -> some View {
        let position = handlePosition(in: size)
        return ZStack {
            // The rift line.
            Rectangle()
                .fill(Theme.iridescent)
                .frame(
                    width: axis == .vertical ? size.width : 2.5,
                    height: axis == .vertical ? 2.5 : size.height
                )
                .shadow(color: .white.opacity(0.6), radius: isDragging ? 6 : 2)

            // Grab handle.
            Image(systemName: axis == .vertical ? "chevron.up.chevron.down" : "chevron.left.chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(9)
                .glassEffect(.regular.interactive(), in: .circle)
                .scaleEffect(isDragging ? 1.2 : 1.0)
                .animation(Theme.chipSpring, value: isDragging)
        }
        .position(position)
        .opacity(fraction >= 0.995 && !isDragging ? 0.45 : 1)
    }

    private func handlePosition(in size: CGSize) -> CGPoint {
        switch axis {
        case .vertical:
            CGPoint(x: size.width / 2, y: fraction * size.height)
        case .horizontal:
            CGPoint(x: fraction * size.width, y: size.height / 2)
        }
    }

    // MARK: Drag + fold snap

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                isDragging = true
                let raw: CGFloat = switch axis {
                case .vertical: value.location.y / max(size.height, 1)
                case .horizontal: value.location.x / max(size.width, 1)
                }
                fraction = snap(min(1, max(0, raw)))
            }
            .onEnded { _ in
                isDragging = false
                // Ease back to fully transformed when parked near the edge.
                if fraction > 0.92 {
                    withAnimation(Theme.chipSpring) { fraction = 1.0 }
                }
            }
    }

    private func snap(_ value: CGFloat) -> CGFloat {
        guard let snapFraction else { return value }
        // Magnetic band around the fold line (spec: "snaps to the fold").
        if abs(value - snapFraction) < 0.045 {
            return snapFraction
        }
        return value
    }
}
