//
//  DetectionOverlay.swift
//  Morpho
//
//  Draws the autodetection layer over the Deck's viewfinder: a dashed outline
//  traced around each tracked region, riding the video, with a one-or-two
//  word name beside it. No boxes, no fills, so overlapping regions stay
//  legible. A region carrying a targeted cast draws solid with the cast's
//  title; the one being spoken to draws brighter. Purely visual and never
//  intercepts touches. Lower screen only.
//

import SwiftUI

struct DetectionOverlay: View {
    let segmentation: SceneSegmentation?
    /// The viewfinder's zoom, so the outlines land on the pixels they describe.
    var zoom: CGFloat = 1
    /// Region id → the augmentation riding it (solid outline, titled chip).
    var augmentedRegions: [Int: TargetedAugmentation] = [:]
    /// The region being spoken to right now.
    var lockedRegionID: Int?

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
                    let augmentation = augmentedRegions[region.id]
                    let locked = region.id == lockedRegionID
                    let dash: [CGFloat] = augmentation == nil && !locked ? [7, 5] : []
                    let width: CGFloat = locked ? 3 : (augmentation == nil ? 2 : 2.5)

                    // A dark halo under the dashes keeps them readable on bright video.
                    path.stroke(.black.opacity(0.35), style: StrokeStyle(lineWidth: width + 2, lineCap: .round, lineJoin: .round, dash: dash))
                    path.stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))

                    RegionLabel(
                        text: region.label,
                        color: color,
                        augmentationTitle: augmentation?.shortTitle,
                        locked: locked
                    )
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
        TargetGeometry.displayRect(frameSize: frameSize, in: container, zoom: zoom)
    }

    static func point(_ normalized: CGPoint, in frame: CGRect) -> CGPoint {
        TargetGeometry.displayPoint(normalized, in: frame)
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

/// The name chip: a color dot and up to two words on dark glass, plus the
/// cast's title once the region carries one ("Person · Ninja").
private struct RegionLabel: View {
    let text: String
    let color: Color
    var augmentationTitle: String?
    var locked = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text.isEmpty ? "…" : text)
                .font(.system(.caption).weight(.semibold))
                .foregroundStyle(.white.opacity(text.isEmpty ? 0.55 : 0.95))
                .lineLimit(1)
            if let augmentationTitle {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.iridescent)
                Text(augmentationTitle)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.iridescent)
                    .lineLimit(1)
            } else if locked {
                Image(systemName: "mic.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse)
            }
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
