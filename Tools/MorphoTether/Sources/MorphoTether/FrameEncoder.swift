//
//  FrameEncoder.swift
//  MorphoTether
//
//  Rotates, crops, downscales, and JPEG-encodes captured frames on the GPU.
//

import CoreImage
import CoreVideo
import Foundation
import ImageIO

final class FrameEncoder {
    struct Encoded {
        var data: Data
        var width: Int
        var height: Int
    }

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Longest side after scaling.
    private let maxSize: CGFloat
    private let quality: CGFloat
    /// Clockwise degrees: 0, 90, 180, or 270.
    private let rotation: Int
    /// Normalized, top-left-origin crop applied after rotation, before scaling.
    private let crop: CGRect?

    init(maxSize: CGFloat, quality: CGFloat, rotation: Int, crop: CGRect?) {
        self.maxSize = maxSize
        self.quality = quality
        self.rotation = rotation
        self.crop = crop
    }

    func encode(_ pixelBuffer: CVPixelBuffer) -> Encoded? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)

        switch rotation {
        case 90: image = image.oriented(.right)
        case 180: image = image.oriented(.down)
        case 270: image = image.oriented(.left)
        default: break
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

        if let crop {
            // CoreImage's origin is bottom-left; flip the normalized y.
            let extent = image.extent
            let rect = CGRect(
                x: crop.minX * extent.width,
                y: (1 - crop.maxY) * extent.height,
                width: crop.width * extent.width,
                height: crop.height * extent.height
            ).integral
            image = image
                .cropped(to: rect)
                .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        }

        let scale = min(1, maxSize / max(image.extent.width, image.extent.height))
        if scale < 1 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let size = CGSize(width: floor(image.extent.width), height: floor(image.extent.height))
        image = image.cropped(to: CGRect(origin: .zero, size: size))

        guard let data = context.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        ) else { return nil }

        return Encoded(data: data, width: Int(size.width), height: Int(size.height))
    }
}
