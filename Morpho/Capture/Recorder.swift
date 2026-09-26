//
//  Recorder.swift
//  Morpho
//
//  Captures the transformed stream (spec §9): MP4 recording via AVAssetWriter,
//  Loopcast GIF export, and single-frame stills.
//

import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

final class Recorder {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstFrameAt: Date?

    /// True between `begin` and `finish`.
    var isWriting: Bool { writer?.status == .writing }

    // MARK: MP4 recording

    func begin(width: Int, height: Int) {
        let url = Self.temporaryURL(extension: "mp4")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else { return }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.firstFrameAt = nil
    }

    func append(_ frame: CGImage) {
        guard
            let input, let adaptor, writer?.status == .writing,
            input.isReadyForMoreMediaData,
            let pool = adaptor.pixelBufferPool
        else { return }

        let now = Date.now
        if firstFrameAt == nil { firstFrameAt = now }
        let elapsed = now.timeIntervalSince(firstFrameAt ?? now)
        let time = CMTime(seconds: elapsed, preferredTimescale: 600)

        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            let rect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            context.draw(frame, in: rect)
        }
        adaptor.append(buffer, withPresentationTime: time)
    }

    func finish(startedAt: Date?) async -> URL? {
        guard let writer, let input else { return nil }
        input.markAsFinished()
        await writer.finishWriting()
        let url = writer.status == .completed ? writer.outputURL : nil
        // A new recording may have begun while this one was finishing; leave it alone.
        if self.writer === writer {
            self.writer = nil
            self.input = nil
            self.adaptor = nil
        }
        return url
    }

    // MARK: Loopcast GIF

    static func writeGIF(frames: [CGImage], fps: Int) async -> URL? {
        guard !frames.isEmpty else { return nil }
        let url = temporaryURL(extension: "gif")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil
        ) else { return nil }

        // Loop forever.
        let fileProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProperties)

        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)],
        ] as CFDictionary
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }

    // MARK: Stills

    static func writeStill(_ frame: CGImage) -> URL? {
        let url = temporaryURL(extension: "png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, frame, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }

    private static func temporaryURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Morpho-\(UUID().uuidString.prefix(8))")
            .appendingPathExtension(ext)
    }
}
