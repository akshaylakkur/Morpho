//
//  FrameSources.swift
//  Morpho
//
//  The VideoSource abstraction (spec §6.1): the app treats a bundled clip, the
//  local camera, and a Tether relay identically behind one frame-stream shape.
//

import AVFoundation
import CoreImage
import UIKit

protocol VideoFrameSource: AnyObject {
    /// Begin producing frames; the handler is called on the main actor.
    func start(onFrame: @escaping @MainActor (CGImage) -> Void)
    func stop()
}

// MARK: - Tier 1a: bundled demo clip

/// Loops `DemoClip.mp4` from the bundle (well-lit, steady, single subject —
/// per Lucy input guidance, spec §12). Used automatically when present.
final class BundledClipSource: VideoFrameSource {
    static var clipURL: URL? {
        Bundle.main.url(forResource: "DemoClip", withExtension: "mp4")
    }

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var output: AVPlayerItemVideoOutput?
    private var displayTask: Task<Void, Never>?
    private let ciContext = CIContext()

    func start(onFrame: @escaping @MainActor (CGImage) -> Void) {
        guard let url = Self.clipURL else { return }
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        let player = AVQueuePlayer()
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true
        player.play()
        self.player = player
        self.output = output

        displayTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, let frame = self.copyCurrentFrame() {
                    onFrame(frame)
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func copyCurrentFrame() -> CGImage? {
        guard let output, let player else { return nil }
        let time = player.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else { return nil }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    func stop() {
        displayTask?.cancel()
        displayTask = nil
        player?.pause()
        player = nil
        looper = nil
        output = nil
    }
}

// MARK: - Tier 1b: synthetic clip (zero-asset guarantee)

/// Procedurally animated stand-in used when no DemoClip.mp4 is bundled, so the
/// full voice → transform loop always has moving pixels to act on.
final class SyntheticClipSource: VideoFrameSource {
    private var renderTask: Task<Void, Never>?
    private let size = CGSize(width: 480, height: 854) // 9:16 portrait, like Lucy's input

    func start(onFrame: @escaping @MainActor (CGImage) -> Void) {
        let size = self.size
        renderTask = Task {
            let start = Date.now
            while !Task.isCancelled {
                let t = Date.now.timeIntervalSince(start)
                if let frame = Self.drawFrame(at: t, size: size) {
                    onFrame(frame)
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    func stop() {
        renderTask?.cancel()
        renderTask = nil
    }

    private static func drawFrame(at t: TimeInterval, size: CGSize) -> CGImage? {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cg = context.cgContext

            // Slowly drifting dusk gradient backdrop.
            let hueShift = CGFloat(0.05 * sin(t * 0.3))
            let top = UIColor(hue: 0.62 + hueShift, saturation: 0.55, brightness: 0.35, alpha: 1)
            let bottom = UIColor(hue: 0.72 + hueShift, saturation: 0.50, brightness: 0.16, alpha: 1)
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [top.cgColor, bottom.cgColor] as CFArray,
                locations: [0, 1]
            )!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

            // Floating light orbs so motion is obvious in the transformed feed.
            for i in 0..<4 {
                let phase = t * (0.4 + Double(i) * 0.13) + Double(i) * 1.7
                let x = size.width * (0.5 + 0.38 * CGFloat(sin(phase)))
                let y = size.height * (0.28 + 0.18 * CGFloat(cos(phase * 0.8)) + CGFloat(i) * 0.12)
                let radius = 24.0 + 10.0 * CGFloat(i)
                UIColor(white: 1, alpha: 0.16).setFill()
                cg.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }

            // A bobbing "subject" silhouette in the lower third.
            let bob = 8.0 * CGFloat(sin(t * 1.2))
            let subjectColor = UIColor(hue: 0.08, saturation: 0.25, brightness: 0.85, alpha: 1)
            subjectColor.setFill()
            let headRadius: CGFloat = 62
            let headCenter = CGPoint(x: size.width / 2, y: size.height * 0.58 + bob)
            cg.fillEllipse(in: CGRect(
                x: headCenter.x - headRadius, y: headCenter.y - headRadius,
                width: headRadius * 2, height: headRadius * 2
            ))
            let torso = UIBezierPath(
                roundedRect: CGRect(
                    x: size.width / 2 - 110, y: headCenter.y + headRadius - 6,
                    width: 220, height: size.height * 0.4
                ),
                cornerRadius: 80
            )
            torso.fill()
        }
        return image.cgImage
    }
}

// MARK: - Tier 2: local camera (device) 

final class CameraFrameSource: NSObject, VideoFrameSource {
    private let session = AVCaptureSession()
    private let outputQueue = DispatchQueue(label: "morpho.camera.frames")
    private let ciContext = CIContext()
    private var handler: (@MainActor (CGImage) -> Void)?

    var usesFrontCamera = true

    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    func start(onFrame: @escaping @MainActor (CGImage) -> Void) {
        handler = onFrame
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else { return }
            self.configureAndRun()
        }
    }

    private func configureAndRun() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        session.inputs.forEach(session.removeInput)
        let position: AVCaptureDevice.Position = usesFrontCamera ? .front : .back
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
            let input = try? AVCaptureDeviceInput(device: device)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        if session.outputs.isEmpty {
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: outputQueue)
            session.addOutput(output)
        }
        session.commitConfiguration()
        outputQueue.async { [session] in session.startRunning() }
    }

    func stop() {
        handler = nil
        outputQueue.async { [session] in session.stopRunning() }
    }
}

extension CameraFrameSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        Task { @MainActor [weak self] in
            self?.handler?(cgImage)
        }
    }
}
