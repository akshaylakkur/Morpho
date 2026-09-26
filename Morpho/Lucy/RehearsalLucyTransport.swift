//
//  RehearsalLucyTransport.swift
//  Morpho
//
//  A stand-in for Lucy 2.5 that runs the whole live pipeline locally and
//  free: it takes the same conditioned 1280×720 uplink frames, enforces the
//  same contract (prompt length, reference-image rules, frame shape, ack per
//  prompt), bills seconds the same way, and sends transformed frames back
//  through the same downlink. Its "transform" is the simulated look plus a
//  tint on each targeted thing where the tracker says it is now, so you can
//  watch an augmentation ride its object as it moves.
//

import CoreImage
import CoreVideo
import Foundation
import UIKit

final class RehearsalLucyTransport: LucyTransport {
    /// Where a targeted cast's thing is now, normalized to the source frame (upper-left origin).
    struct TrackedRegion: Sendable {
        var box: CGRect
        var title: String
    }

    var onEvent: ((LucyTransportEvent) -> Void)?
    /// The engine's tracker, read once per output frame.
    var trackedRegions: (() -> [TrackedRegion])?
    /// Source frame size, to map tracked boxes through the uplink's aspect-fill.
    var sourceSize: (() -> CGSize?)?

    static let connectDelay: Duration = .milliseconds(1400)
    static let ackDelay: Duration = .milliseconds(350)

    private let inbox = RehearsalInbox()
    private let context = CIContext()
    private var format = LucyStreamFormat.portrait
    private var directive: LucyDirective?
    private var renderTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var connectedAt: Date?
    private var generated: Double = 0

    func connect(format: LucyStreamFormat, directive: LucyDirective, firstFrame: CVPixelBuffer) async throws {
        try Self.validate(directive)
        try Self.validate(firstFrame, against: format)
        self.format = format
        inbox.put(firstFrame)
        try await Task.sleep(for: Self.connectDelay)
        self.directive = directive
        connectedAt = .now
        generated = 0
        onEvent?(.connected)
        startLoops()
    }

    nonisolated func send(_ frame: CVPixelBuffer) {
        inbox.put(frame)
    }

    func apply(_ directive: LucyDirective) async throws {
        guard connectedAt != nil else { throw LucyTransportError.rejected("Not connected") }
        try Self.validate(directive)
        try await Task.sleep(for: Self.ackDelay)
        self.directive = directive
    }

    func disconnect() async {
        renderTask?.cancel()
        meterTask?.cancel()
        renderTask = nil
        meterTask = nil
        connectedAt = nil
        directive = nil
    }

    /// Console hook: drop the link for a moment, the way a network blip would.
    func simulateDrop() {
        guard connectedAt != nil else { return }
        onEvent?(.reconnecting)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.connectedAt != nil else { return }
            self.onEvent?(.connected)
        }
    }

    // MARK: Contract checks (what Lucy would reject)

    static func validate(_ directive: LucyDirective) throws {
        let text = directive.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > LucyPromptSpec.maxLength {
            throw LucyTransportError.rejected("Prompt is \(text.count) characters; Lucy takes \(LucyPromptSpec.maxLength)")
        }
        if text.isEmpty {
            throw LucyTransportError.rejected("Empty prompt")
        }
        if let image = directive.referenceImageData, image.count >= 5 * 1024 * 1024 {
            throw LucyTransportError.rejected("Reference image is over 5 MB")
        }
    }

    static func validate(_ frame: CVPixelBuffer, against format: LucyStreamFormat) throws {
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        guard width == format.width, height == format.height else {
            throw LucyTransportError.rejected("Frame is \(width)×\(height); the session expects \(format.width)×\(format.height)")
        }
    }

    // MARK: Loops

    private func startLoops() {
        renderTask?.cancel()
        renderTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.renderLatest()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let connectedAt = self.connectedAt else { return }
                self.generated = Date.now.timeIntervalSince(connectedAt)
                self.onEvent?(.generatedSeconds(self.generated))
            }
        }
    }

    private func renderLatest() {
        guard let directive, let frame = inbox.take() else { return }
        let input = CIImage(cvPixelBuffer: frame)
        var output = input
        if directive.parts.contains(where: { $0.kind == .scene }) {
            output = SimulatedLucy.transform(
                input,
                spec: LucyPromptSpec(editType: .style, prompt: directive.text, confidence: 1),
                realmID: nil,
                time: Date.now.timeIntervalSince(connectedAt ?? .now)
            )
        }
        output = tintTrackedRegions(on: output)
        if let image = context.createCGImage(output, from: input.extent) {
            onEvent?(.output(image, luma: nil))
        }
    }

    /// Washes each targeted thing in color where the tracker has it now.
    private func tintTrackedRegions(on image: CIImage) -> CIImage {
        guard let regions = trackedRegions?(), !regions.isEmpty, let source = sourceSize?(),
              source.width > 0, source.height > 0
        else { return image }
        let width = CGFloat(format.width)
        let height = CGFloat(format.height)
        let scale = max(width / source.width, height / source.height)
        let offsetX = (source.width * scale - width) / 2
        let offsetY = (source.height * scale - height) / 2
        var result = image
        for (index, region) in regions.enumerated() {
            // Upper-left normalized source → uplink pixels → Core Image's lower-left origin.
            let x = region.box.minX * source.width * scale - offsetX
            let top = region.box.minY * source.height * scale - offsetY
            let w = region.box.width * source.width * scale
            let h = region.box.height * source.height * scale
            let rect = CGRect(x: x, y: height - top - h, width: w, height: h).intersection(image.extent)
            guard !rect.isNull, rect.width > 1, rect.height > 1 else { continue }
            let hue = CGFloat(index) * 0.23 + 0.78
            let color = UIColor(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.85, brightness: 1, alpha: 0.38)
            let wash = CIImage(color: CIColor(color: color)).cropped(to: rect)
            result = wash.composited(over: result)
        }
        return result
    }
}

/// The newest uplink frame, handed from the encoder queue to the render loop.
nonisolated final class RehearsalInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CVPixelBuffer?

    func put(_ frame: CVPixelBuffer) {
        lock.withLock { self.frame = frame }
    }

    func take() -> CVPixelBuffer? {
        lock.withLock {
            defer { frame = nil }
            return frame
        }
    }
}
