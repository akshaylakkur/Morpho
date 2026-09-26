//
//  LucyFrameEncoder.swift
//  Morpho
//
//  Uplink conditioning: every source (tether, camera, demo clip) delivers
//  CGImages of whatever size it has; Lucy wants 1280×720 (or 720×1280) at up
//  to 30 fps. This aspect-fills each frame into a pooled BGRA pixel buffer on
//  its own queue and hands it to the transport. A frame that arrives while
//  the previous one is still encoding is dropped, never queued, so the
//  uplink can't build latency.
//

import CoreImage
import CoreVideo
import Foundation

nonisolated final class LucyFrameEncoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "morpho.lucy.encoder", qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()

    // Guarded by `lock`.
    private var format: LucyStreamFormat?
    private var pool: CVPixelBufferPool?
    private var busy = false
    private var lastEncodedAt: TimeInterval = 0
    private var latest: CVPixelBuffer?
    private var sink: ((CVPixelBuffer) -> Void)?
    private var encodedCount = 0

    /// Starts conditioning frames into `format`; `sink` receives each one on the encoder queue.
    func begin(format: LucyStreamFormat, sink: ((CVPixelBuffer) -> Void)?) {
        lock.withLock {
            if self.format != format {
                self.format = format
                pool = Self.makePool(width: format.width, height: format.height)
                latest = nil
            }
            self.sink = sink
        }
    }

    /// Stops forwarding; the encoder keeps its format and last buffer for priming.
    func pause() {
        lock.withLock { sink = nil }
    }

    func reset() {
        lock.withLock {
            sink = nil
            format = nil
            pool = nil
            latest = nil
        }
    }

    var currentFormat: LucyStreamFormat? { lock.withLock { format } }

    /// The most recent conditioned frame, used to prime a new session.
    var latestFrame: CVPixelBuffer? { lock.withLock { latest } }

    /// Frames encoded since the last call; the director turns this into fps.
    func drainCount() -> Int {
        lock.withLock {
            defer { encodedCount = 0 }
            return encodedCount
        }
    }

    /// Queue one source frame. Cheap on the caller: the work happens on the encoder queue.
    func submit(_ image: CGImage) {
        let now = ProcessInfo.processInfo.systemUptime
        let accepted: Bool = lock.withLock {
            guard let format, !busy else { return false }
            // Cap at the model's frame rate.
            guard now - lastEncodedAt >= 1.0 / Double(format.fps + 1) else { return false }
            busy = true
            lastEncodedAt = now
            return true
        }
        guard accepted else { return }
        queue.async { [self] in
            let (pool, format) = lock.withLock { (self.pool, self.format) }
            var output: CVPixelBuffer?
            if let pool, let format {
                output = encode(image, format: format, pool: pool)
            }
            let sink: ((CVPixelBuffer) -> Void)? = lock.withLock {
                busy = false
                if let output {
                    latest = output
                    encodedCount += 1
                }
                return self.sink
            }
            if let output { sink?(output) }
        }
    }

    private func encode(_ image: CGImage, format: LucyStreamFormat, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        let filled = Self.aspectFill(CIImage(cgImage: image), width: format.width, height: format.height)
        context.render(filled, to: buffer, bounds: CGRect(x: 0, y: 0, width: format.width, height: format.height), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }

    /// Center-crop to the target aspect, then scale — the same framing the Stage shows (scaledToFill).
    static func aspectFill(_ image: CIImage, width: Int, height: Int) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = max(CGFloat(width) / extent.width, CGFloat(height) / extent.height)
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let offsetX = (scaled.extent.width - CGFloat(width)) / 2
        let offsetY = (scaled.extent.height - CGFloat(height)) / 2
        return scaled
            .transformed(by: CGAffineTransform(translationX: -offsetX, y: -offsetY))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attributes as CFDictionary, &pool)
        return pool
    }
}
