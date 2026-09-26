//
//  SimulatedLucy.swift
//  Morpho
//
//  A stand-in for Lucy 2.5 Realtime so the entire experience — casting,
//  generation states, the Rift Slider, recording — runs before credentials
//  and the DecartSDK package are added. Each Realm gets a distinct CoreImage
//  look; freeform prompts derive a deterministic look from their text.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum SimulatedLucy {
    static func transform(
        _ input: CIImage,
        spec: LucyPromptSpec?,
        realmID: String?,
        time: TimeInterval
    ) -> CIImage {
        guard spec != nil || realmID != nil else { return input }

        switch realmID {
        case "thunderstorm":
            var image = adjust(input, saturation: 0.7, brightness: -0.18, contrast: 1.15)
            image = tint(image, hue: 0.6, intensity: 0.35)
            // Lightning: a brief global flash every few seconds.
            let cycle = time.truncatingRemainder(dividingBy: 4.2)
            if cycle < 0.12 {
                image = adjust(image, saturation: 0.9, brightness: 0.5, contrast: 1.0)
            }
            return image
        case "claymation":
            let posterize = CIFilter.colorPosterize()
            posterize.inputImage = adjust(input, saturation: 1.35, brightness: 0.05, contrast: 1.05)
            posterize.levels = 7
            return posterize.outputImage ?? input
        case "neo-tokyo":
            var image = adjust(input, saturation: 1.5, brightness: -0.05, contrast: 1.2)
            image = tint(image, hue: 0.87, intensity: 0.4)
            return image
        case "origami":
            let crystallize = CIFilter.crystallize()
            crystallize.inputImage = adjust(input, saturation: 0.85, brightness: 0.12, contrast: 0.95)
            crystallize.radius = 14
            crystallize.center = CGPoint(x: input.extent.midX, y: input.extent.midY)
            return crystallize.outputImage?.cropped(to: input.extent) ?? input
        case "golden-hour":
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = adjust(input, saturation: 1.1, brightness: 0.06, contrast: 1.0)
            temperature.neutral = CIVector(x: 4500, y: 0)
            temperature.targetNeutral = CIVector(x: 6500, y: 0)
            return temperature.outputImage ?? input
        case "underwater":
            var image = adjust(input, saturation: 0.9, brightness: -0.04, contrast: 1.0)
            image = tint(image, hue: 0.5, intensity: 0.45)
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = image
            blur.radius = 1.2
            return blur.outputImage?.cropped(to: input.extent) ?? image
        case "film-noir":
            let mono = CIFilter.photoEffectNoir()
            mono.inputImage = adjust(input, saturation: 1.0, brightness: 0.0, contrast: 1.25)
            return mono.outputImage ?? input
        default:
            // Freeform incantation: derive a stable, visibly-different look
            // from the prompt text so every cast changes the frame.
            let seed = abs((spec?.prompt ?? "").hashValue)
            let hueAngle = Float(seed % 628) / 100.0 // 0…2π
            let hueFilter = CIFilter.hueAdjust()
            hueFilter.inputImage = adjust(input, saturation: 1.25, brightness: 0.02, contrast: 1.08)
            hueFilter.angle = hueAngle
            return hueFilter.outputImage ?? input
        }
    }

    private static func adjust(_ image: CIImage, saturation: Float, brightness: Float, contrast: Float) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.saturation = saturation
        filter.brightness = brightness
        filter.contrast = contrast
        return filter.outputImage ?? image
    }

    private static func tint(_ image: CIImage, hue: CGFloat, intensity: CGFloat) -> CIImage {
        let color = CIColor(
            red: 0.5 + 0.5 * cos(hue * 2 * .pi),
            green: 0.5 + 0.5 * cos((hue - 0.33) * 2 * .pi),
            blue: 0.5 + 0.5 * cos((hue - 0.66) * 2 * .pi)
        )
        let overlay = CIImage(color: color)
            .cropped(to: image.extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: intensity),
            ])
        return overlay.composited(over: image)
    }
}
