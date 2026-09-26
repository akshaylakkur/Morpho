//
//  TargetDescriber.swift
//  Morpho
//
//  Words for a selection nobody named: a hand-drawn crop, or a region the
//  detector could only call "Object". Lucy finds what a prompt describes by
//  its visible details, so "the selected object" gives it nothing to go on;
//  "the dark gray object in the lower left of the frame" does. The color
//  comes from the crop's average, the place from where the box sits.
//

import CoreGraphics
import CoreImage
import UIKit

enum TargetDescriber {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// "dark gray object in the lower left of the frame" (no article).
    static func describe(crop: CGImage?, box: CGRect) -> String {
        let color = crop.flatMap(averageColor).map(colorName)
        let thing = [color, "object"].compactMap { $0 }.joined(separator: " ")
        return "\(thing) \(placement(of: box))"
    }

    /// "in the lower left of the frame", "in the center of the frame".
    static func placement(of box: CGRect) -> String {
        let vertical = box.midY < 1.0 / 3 ? "upper" : (box.midY > 2.0 / 3 ? "lower" : nil)
        let horizontal = box.midX < 1.0 / 3 ? "left" : (box.midX > 2.0 / 3 ? "right" : nil)
        switch (vertical, horizontal) {
        case (nil, nil): return "in the center of the frame"
        case (let v?, nil): return "in the \(v) middle of the frame"
        case (nil, let h?): return "on the \(h) side of the frame"
        case (let v?, let h?): return "in the \(v) \(h) of the frame"
        }
    }

    static func averageColor(of image: CGImage) -> UIColor? {
        let input = CIImage(cgImage: image)
        guard let average = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input,
            kCIInputExtentKey: CIVector(cgRect: input.extent),
        ])?.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    /// A plain color word a person (and Lucy) would use.
    static func colorName(_ color: UIColor) -> String {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        if brightness < 0.18 { return "black" }
        if saturation < 0.15 {
            switch brightness {
            case ..<0.4: return "dark gray"
            case ..<0.7: return "gray"
            case ..<0.88: return "light gray"
            default: return "white"
            }
        }
        let degrees = hue * 360
        let base: String
        switch degrees {
        case ..<15, 345...: base = "red"
        case ..<40: base = saturation < 0.55 || brightness < 0.6 ? "brown" : "orange"
        case ..<65: base = brightness < 0.6 ? "olive" : "yellow"
        case ..<165: base = "green"
        case ..<200: base = "teal"
        case ..<255: base = "blue"
        case ..<290: base = "purple"
        default: base = "pink"
        }
        if base == "brown" || base == "olive" { return base }
        return brightness < 0.45 ? "dark \(base)" : base
    }
}
