//
//  DecartLucyTransport.swift
//  Morpho
//
//  The live Lucy 2.5 Realtime backend (DecartSDK 0.7.1 + LiveKit). Frames
//  go up through a LiveKit buffer track fed by LucyFrameEncoder — the same
//  conditioned frames whatever the source (tether, camera, demo clip) — and
//  the transformed remote track is tapped frame by frame back into the
//  engine, so the Stage, the Rift Slider, the recorder, and Loopcast all
//  work on Lucy's output exactly as they do on the simulation.
//
//  See docs/DECART_LUCY_2_5.md for the contract this follows.
//

#if canImport(DecartSDK)
import CoreImage
import CoreVideo
import DecartSDK
import Foundation
@preconcurrency import LiveKit

final class DecartLucyTransport: LucyTransport {
    var onEvent: ((LucyTransportEvent) -> Void)?

    private let apiKey: String
    private var manager: DecartRealtimeManager?
    private var localTrack: LocalVideoTrack?
    private let uplink = DecartUplink()
    private let tap = LucyOutputTap()
    private var remoteTrack: VideoTrack?
    private var eventsTask: Task<Void, Never>?
    private var remoteStreamsTask: Task<Void, Never>?
    private var closing = false
    /// Until connect() returns, failures surface as its thrown error (with
    /// Lucy's real reason), not as a generic `.ended` event.
    private var didConnect = false
    private var lastConnectionState: DecartRealtimeConnectionState?

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func connect(format: LucyStreamFormat, directive: LucyDirective, firstFrame: CVPixelBuffer) async throws {
        closing = false
        didConnect = false
        let client = DecartClient(decartConfiguration: DecartConfiguration(apiKey: apiKey))
        let manager = try client.createRealtimeManager(options: RealtimeConfiguration(
            model: Models.realtime(.lucy2_5),
            // The first frame back is already transformed.
            initialPrompt: Self.prompt(for: directive)
        ))
        self.manager = manager

        let track = await LocalVideoTrack.createBufferTrack(name: "morpho_uplink", source: .camera)
        localTrack = track
        uplink.attach(track.capturer as? BufferCapturer)
        // A buffer track must carry a frame before it can be published.
        uplink.send(firstFrame)

        tap.onFrame = { [weak self] image, luma in
            self?.onEvent?(.output(image, luma: luma))
        }

        eventsTask = Task { @MainActor [weak self] in
            for await state in manager.events {
                self?.handle(state)
            }
        }

        let remote: RealtimeMediaStream
        do {
            remote = try await manager.connect(localStream: RealtimeMediaStream(videoTrack: track, id: .localStream))
        } catch {
            await teardown()
            throw error
        }
        bind(remote.videoTrack)

        // After every successful auto-reconnect the SDK hands over a new remote stream.
        remoteStreamsTask = Task { @MainActor [weak self] in
            for await stream in manager.remoteStreamUpdates {
                self?.bind(stream.videoTrack)
            }
        }
        didConnect = true
        onEvent?(.connected)
    }

    nonisolated func send(_ frame: CVPixelBuffer) {
        uplink.send(frame)
    }

    func apply(_ directive: LucyDirective) async throws {
        guard let manager else { throw LucyTransportError.rejected("Not connected") }
        do {
            try await manager.setPrompt(Self.prompt(for: directive))
        } catch let error as DecartError {
            if case .serverError(let message) = error, message.contains("superseded") {
                throw LucyTransportError.superseded
            }
            throw error
        }
    }

    func disconnect() async {
        closing = true
        await teardown()
    }

    // MARK: Internals

    private static func prompt(for directive: LucyDirective) -> DecartPrompt {
        // set_image replaces atomically: the reference image rides along every time.
        DecartPrompt(text: directive.text, referenceImageData: directive.referenceImageData, enrich: directive.enrich)
    }

    private func bind(_ track: VideoTrack?) {
        guard remoteTrack !== track else { return }
        remoteTrack?.remove(videoRenderer: tap)
        remoteTrack = track
        track?.add(videoRenderer: tap)
    }

    private func handle(_ state: DecartRealtimeState) {
        if let seconds = state.generationTick {
            onEvent?(.generatedSeconds(seconds))
        }
        if state.serviceStatus == .enteringQueue || state.queuePosition != nil, !state.connectionState.isConnected {
            onEvent?(.queued(position: state.queuePosition))
        }
        guard state.connectionState != lastConnectionState else { return }
        let previous = lastConnectionState
        lastConnectionState = state.connectionState
        switch state.connectionState {
        case .connected, .generating:
            // The initial connect is reported by connect() itself once the remote track is bound.
            if previous == .reconnecting { onEvent?(.connected) }
        case .reconnecting:
            onEvent?(.reconnecting)
        case .error:
            if !closing, didConnect { onEvent?(.ended(reason: "Lucy ended the session (reconnect attempts exhausted or credentials rejected)")) }
        case .disconnected:
            if !closing, didConnect, previous != nil, previous != .connecting { onEvent?(.ended(reason: "Lucy disconnected")) }
        case .connecting, .idle:
            break
        @unknown default:
            break
        }
    }

    private func teardown() async {
        eventsTask?.cancel()
        remoteStreamsTask?.cancel()
        eventsTask = nil
        remoteStreamsTask = nil
        remoteTrack?.remove(videoRenderer: tap)
        remoteTrack = nil
        tap.onFrame = nil
        uplink.attach(nil)
        if let localTrack {
            try? await localTrack.stop()
        }
        localTrack = nil
        if let manager {
            await manager.disconnect()
        }
        manager = nil
        lastConnectionState = nil
    }
}

/// Holds the capturer for the encoder queue.
nonisolated final class DecartUplink: @unchecked Sendable {
    private let lock = NSLock()
    private var capturer: BufferCapturer?

    func attach(_ capturer: BufferCapturer?) {
        lock.withLock { self.capturer = capturer }
    }

    func send(_ frame: CVPixelBuffer) {
        let capturer = lock.withLock { self.capturer }
        capturer?.capture(frame)
    }
}

/// Taps Lucy's remote track: each decoded frame becomes a CGImage on the
/// main actor, dropping frames while the previous one is still converting.
nonisolated final class LucyOutputTap: NSObject, VideoRenderer, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "morpho.lucy.downlink", qos: .userInteractive)
    private let lock = NSLock()
    private var inFlight = false
    private var handler: (@MainActor (CGImage, Double?) -> Void)?

    var onFrame: (@MainActor (CGImage, Double?) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { .zero }

    func render(frame: VideoFrame) {
        let proceed: Bool = lock.withLock {
            guard handler != nil, !inFlight else { return false }
            inFlight = true
            return true
        }
        guard proceed else { return }
        queue.async { [self] in
            let converted = convert(frame)
            let handler = lock.withLock { self.handler }
            guard let converted, let handler else {
                lock.withLock { inFlight = false }
                return
            }
            Task { @MainActor [weak self] in
                handler(converted.image, converted.luma)
                self?.lock.withLock { self?.inFlight = false }
            }
        }
    }

    /// The frame as a CGImage, plus its brightness so warm-up frames can be held back.
    private func convert(_ frame: VideoFrame) -> (image: CGImage, luma: Double?)? {
        guard let buffer = frame.toCVPixelBuffer() else { return nil }
        var image = CIImage(cvPixelBuffer: buffer)
        switch frame.rotation {
        case ._90: image = image.oriented(.right)
        case ._180: image = image.oriented(.down)
        case ._270: image = image.oriented(.left)
        default: break
        }
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        return (cgImage, LucyFrameProbe.meanLuma(of: image, context: context))
    }
}
#endif
