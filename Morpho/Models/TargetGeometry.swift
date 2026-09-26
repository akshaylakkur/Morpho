//
//  TargetGeometry.swift
//  Morpho
//
//  Maps between the viewfinder's screen space and the frame's normalized
//  space (upper-left origin), and resolves which detected region a point or
//  rectangle means. Shared by the detection overlay and the targeting layer
//  so outlines, hit tests and marquees all land on the same pixels.
//

import CoreGraphics
import Foundation

enum TargetGeometry {
    /// Where the frame lands on screen: scale-to-fill plus the viewfinder zoom.
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

    static func displayPoint(_ normalized: CGPoint, in display: CGRect) -> CGPoint {
        CGPoint(x: display.minX + normalized.x * display.width, y: display.minY + normalized.y * display.height)
    }

    static func displayRect(_ normalized: CGRect, in display: CGRect) -> CGRect {
        CGRect(
            x: display.minX + normalized.minX * display.width,
            y: display.minY + normalized.minY * display.height,
            width: normalized.width * display.width,
            height: normalized.height * display.height
        )
    }

    /// Screen point → normalized frame point (may fall outside 0…1 when the frame is zoomed out).
    static func normalizedPoint(_ point: CGPoint, in display: CGRect) -> CGPoint {
        CGPoint(
            x: (point.x - display.minX) / max(display.width, 1),
            y: (point.y - display.minY) / max(display.height, 1)
        )
    }

    /// Screen rect → normalized frame rect, clamped to the frame.
    static func normalizedRect(_ rect: CGRect, in display: CGRect) -> CGRect {
        let origin = normalizedPoint(rect.origin, in: display)
        let raw = CGRect(x: origin.x, y: origin.y, width: rect.width / max(display.width, 1), height: rect.height / max(display.height, 1))
        return raw.standardized.intersection(unit)
    }

    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// The region under a normalized point: the smallest one whose box
    /// contains it (with a little slop), so a mug on a table wins over the table.
    static func region(at point: CGPoint, in regions: [DetectedRegion], slop: CGFloat = 0.015) -> DetectedRegion? {
        regions
            .filter { $0.boundingBox.insetBy(dx: -slop, dy: -slop).contains(point) }
            .min { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
    }

    /// The region a hand-drawn rectangle most plausibly meant, if any overlaps it enough.
    static func bestMatch(for rect: CGRect, in regions: [DetectedRegion], minimumIoU: CGFloat = 0.3) -> DetectedRegion? {
        let scored = regions.map { ($0, iou(rect, $0.boundingBox)) }.filter { $0.1 >= minimumIoU }
        return scored.max { $0.1 < $1.1 }?.0
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        guard !overlap.isNull, !overlap.isEmpty else { return 0 }
        let union = a.width * a.height + b.width * b.height - overlap.width * overlap.height
        return union > 0 ? (overlap.width * overlap.height) / union : 0
    }
}
