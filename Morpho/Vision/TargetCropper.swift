//
//  TargetCropper.swift
//  Morpho
//
//  Cuts a locked target out of its held frame: a tight crop for the
//  on-device model to look at, and the same crop padded to Lucy's aspect
//  (16:9 or 9:16, at least 512 px, never cropped to fit) for the cast bundle.
//

import CoreGraphics
import Foundation
import UIKit

enum TargetCropper {
    struct Crops {
        var tight: CGImage
        var tightJPEG: Data?
        var lucyJPEG: Data?
    }

    /// Context around the object, as a fraction of its box.
    static let padding: CGFloat = 0.08
    static let minimumLongSide = 1024
    static let maximumLongSide = 1280

    static func crops(from frame: CGImage, box: CGRect) -> Crops? {
        guard let tight = tightCrop(from: frame, box: box) else { return nil }
        let portrait = frame.height >= frame.width
        let padded = padded(tight, portrait: portrait)
        return Crops(
            tight: tight,
            tightJPEG: UIImage(cgImage: tight).jpegData(compressionQuality: 0.85),
            lucyJPEG: padded.flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.85) }
        )
    }

    /// The box plus a little context, in the frame's pixel space (upper-left origin).
    static func pixelRect(for box: CGRect, in frameSize: CGSize) -> CGRect {
        let paddedBox = box
            .insetBy(dx: -box.width * padding, dy: -box.height * padding)
            .intersection(TargetGeometry.unit)
        return CGRect(
            x: paddedBox.minX * frameSize.width,
            y: paddedBox.minY * frameSize.height,
            width: paddedBox.width * frameSize.width,
            height: paddedBox.height * frameSize.height
        ).integral
    }

    static func tightCrop(from frame: CGImage, box: CGRect) -> CGImage? {
        let rect = pixelRect(for: box, in: CGSize(width: frame.width, height: frame.height))
        guard rect.width >= 4, rect.height >= 4 else { return nil }
        return frame.cropping(to: rect)
    }

    /// A smaller copy for use as model context.
    static func downscaled(_ image: CGImage, longSide: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > longSide else { return image }
        let scale = CGFloat(longSide) / CGFloat(longest)
        let size = CGSize(width: (CGFloat(image.width) * scale).rounded(), height: (CGFloat(image.height) * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    /// Letterboxes the crop onto a black 9:16 or 16:9 canvas sized for Lucy.
    static func padded(_ image: CGImage, portrait: Bool) -> CGImage? {
        let longSide = min(max(max(image.width, image.height), minimumLongSide), maximumLongSide)
        let shortSide = Int((CGFloat(longSide) * 9 / 16).rounded())
        let canvas = portrait
            ? CGSize(width: shortSide, height: longSide)
            : CGSize(width: longSide, height: shortSide)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        let rendered = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: canvas))
            let fit = min(canvas.width / CGFloat(image.width), canvas.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit)
            let origin = CGPoint(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2)
            UIImage(cgImage: image).draw(in: CGRect(origin: origin, size: size))
        }
        return rendered.cgImage
    }
}
