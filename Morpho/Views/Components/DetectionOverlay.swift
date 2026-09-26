//
//  DetectionOverlay.swift
//  Morpho
//
//  Draws the autodetection layer over the Deck's viewfinder: a dashed outline
//  traced around each tracked region, riding the video, with a one-or-two
//  word name beside it. No boxes, no fills, so overlapping regions stay
//  legible. Purely visual and never intercepts touches. Lower screen only.
//

import SwiftUI

struct DetectionOverlay: View {
    let segmentation: SceneSegmentation?
    /// The viewfinder's zoom, so the outlines land on the pixels they describe.
    var zoom: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            let frame = Self.displayRect(
                frameSize: segmentation?.frameSize ?? proxy.size,
                in: proxy.size,
                zoom: zoom
            )

            ZStack(alignment: .topLeading) {
                ForEach(segmentation?.regions ?? []) { region in
                    let color = DetectionPalette.color(region.paletteIndex)
                    let path = Self.path(for: region.outline, in: frame)

                    // A dark halo under the dashes keeps them readable on bright video.
                    path.stroke(.black.opacity(0.35), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [7, 5]))
                    path.stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [7, 5]))

                    RegionLabel(text: region.label, color: color)
                        .offset(Self.labelOffset(for: region, in: frame, container: proxy.size))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .transition(.opacity)
            }
            .animation(.easeOut(duration: 0.2), value: segmentation?.regions.map(\.id))
        }
        .allowsHitTesting(false)
        .clipped()
        .accessibilityHidden(true)
    }

    // MARK: Geometry

    /// Where the frame lands on screen: the same scale-to-fill plus zoom that
    /// `StageFeed` applies, so normalized points map straight onto pixels.
    static func displayRect(frameSize: CGSize, in container: CGSize, zoom: CGFloat) -> CGRect {
        guard frameSize.width > 0, frameSize.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = max(container.width / frameSize.width, container.height / frameSize.height) * max(zoom, 0.01)
        let size = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    static func point(_ normalized: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + normalized.x * frame.width, y: frame.minY + normalized.y * frame.height)
    }

    /// A closed path through the traced outline.
    static func path(for outline: [CGPoint], in frame: CGRect) -> Path {
        var path = Path()
        guard let first = outline.first else { return path }
        path.move(to: point(first, in: frame))
        for normalized in outline.dropFirst() {
            path.addLine(to: point(normalized, in: frame))
        }
        path.closeSubpath()
        return path
    }

    /// Sits just inside the outline's topmost point, nudged back on screen
    /// when the region runs off the edge.
    private static func labelOffset(for region: DetectedRegion, in frame: CGRect, container: CGSize) -> CGSize {
        let anchor = region.outline.min { $0.y < $1.y } ?? CGPoint(x: region.boundingBox.minX, y: region.boundingBox.minY)
        let top = point(anchor, in: frame)
        let estimated = CGSize(width: 120, height: 26)
        let inset: CGFloat = 8
        // The top strip belongs to the Live and timer chips; sit below the
        // outline's top instead of above it up there.
        let chromeBand: CGFloat = 64
        let above = top.y - estimated.height - 4
        let preferredY = above < chromeBand ? top.y + 6 : above
        let x = min(max(top.x - 10, inset), max(inset, container.width - estimated.width - inset))
        let y = min(max(preferredY, inset), max(inset, container.height - estimated.height - inset))
        return CGSize(width: x, height: y)
    }
}

/// The name chip: a color dot and up to two words on dark glass.
private struct RegionLabel: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text.isEmpty ? "…" : text)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.white.opacity(text.isEmpty ? 0.55 : 0.95))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55), in: .capsule)
        .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
        .fixedSize()
    }
}

extension DetectionPalette {
    static func color(_ index: Int) -> Color {
        let entry = rgb[((index % rgb.count) + rgb.count) % rgb.count]
        return Color(
            red: Double(entry.r) / 255,
            green: Double(entry.g) / 255,
            blue: Double(entry.b) / 255
        )
    }
}
