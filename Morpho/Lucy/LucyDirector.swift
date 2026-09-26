//
//  LucyDirector.swift
//  Morpho
//
//  Runs the Lucy link: decides when a session should exist, keeps Lucy's
//  prompt equal to everything cast right now, pumps camera frames up and
//  transformed frames back, and guards the bill.
//
//  Policy
//  • A session exists only while something is cast. The first cast opens it
//    (with the prompt already in place); clearing everything closes it after
//    a short grace, so an idle feed costs nothing.
//  • Every change re-sends the whole scene (LucySceneComposer), so each
//    augmentation stays applied — and keeps tracking its object — until it
//    is removed. Updates are serialized; bursts collapse to the newest.
//  • No camera frames → the session closes after a few seconds and reopens
//    by itself when frames return.
//  • Caps: every session ends after `sessionCapSeconds` (resume by hand);
//    live Lucy stops for the launch at `liveLaunchCapSeconds`.
//  • Live mode is armed by hand each launch and never restored from disk.
//

import CoreGraphics
import CoreVideo
import Foundation
import Observation

@Observable
final class LucyDirector {
    /// Builds the transport for a mode (injectable for tests).
    typealias TransportFactory = (LucyLinkMode) async throws -> LucyTransport

    private let session: SessionModel
    @ObservationIgnored private let makeTransport: TransportFactory
    @ObservationIgnored let encoder = LucyFrameEncoder()

    // MARK: Policy

    struct Policy: Equatable, Sendable {
        /// Grace before closing a session once nothing is cast.
        var idleCloseDelay: Duration = .seconds(6)
        /// How long the camera may be silent before the session closes.
        var stallCloseDelay: Duration = .seconds(4)
        var retryDelay: Duration = .seconds(2)
        var maxRetries = 2
        /// Lucy output older than this is stale; the Stage shows the untouched feed instead.
        var outputStaleAfter: TimeInterval = 1.0
        /// Every session ends here; resuming opens a new one.
        var sessionCapSeconds: Double = 180
        /// Live Lucy stops for the launch here (600 s ≈ $12).
        var liveLaunchCapSeconds: Double = 600
    }

    @ObservationIgnored var policy = Policy()
    static let modeDefaultsKey = "lucyLinkMode"

    // MARK: Per-frame state (not observed)

    @ObservationIgnored private(set) var latestOutput: CGImage?
    @ObservationIgnored private var latestOutputAt = Date.distantPast
    @ObservationIgnored private var downlinkCount = 0
    @ObservationIgnored private(set) var sourceSize: CGSize?

    // MARK: Session state

    @ObservationIgnored private var transport: LucyTransport?
    @ObservationIgnored private var connecting = false
    /// The transport finished connecting; prompt updates may go out.
    @ObservationIgnored private var sessionOpen = false
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var pendingDirective: LucyDirective?
    @ObservationIgnored private var appliedDirective: LucyDirective?
    @ObservationIgnored private var closeTask: Task<Void, Never>?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var retries = 0
    @ObservationIgnored private var liveSecondsBeforeSession: Double = 0
    @ObservationIgnored private var feedStalled = false
    /// Where tracked targets are now, for the rehearsal tint (set by the engine).
    @ObservationIgnored var trackedRegions: (() -> [RehearsalLucyTransport.TrackedRegion])?

    @ObservationIgnored private let defaults: UserDefaults

    init(session: SessionModel, defaults: UserDefaults = .standard, makeTransport: @escaping TransportFactory) {
        self.session = session
        self.defaults = defaults
        self.makeTransport = makeTransport
        // Only the free modes come back across launches.
        if let raw = defaults.string(forKey: Self.modeDefaultsKey),
           let mode = LucyLinkMode(rawValue: raw), mode != .live {
            session.lucy.mode = mode
        }
    }

    private var status: LucyLinkStatus {
        get { session.lucy }
        set { session.lucy = newValue }
    }

    /// True when the feed on screen comes from the transport rather than the simulation.
    var drivesFeed: Bool {
        status.mode.usesTransport && status.directive != nil
    }

    // MARK: Mode

    /// Switches backends. `.live` must only be called after the person confirmed billing.
    func setMode(_ mode: LucyLinkMode) async {
        guard mode != status.mode else { return }
        await closeSession(reason: "Switched to \(mode.displayName)")
        status.mode = mode
        status.phase = .idle
        status.promptState = .none
        retries = 0
        if mode != .live {
            defaults.set(mode.rawValue, forKey: Self.modeDefaultsKey)
        }
        log("Mode: \(mode.displayName)")
        sceneDidChange()
    }

    // MARK: Scene

    /// Something was cast or removed: recompute the prompt and act on it.
    func sceneDidChange() {
        let directive = LucySceneComposer.directive(
            sceneCast: session.lastCast,
            augmentations: session.augmentations,
            referenceImageData: session.referenceImageData,
            enrich: session.enhance
        )
        status.directive = directive
        if let dropped = directive?.droppedTitles, !dropped.isEmpty {
            log("Over the 750-character budget; left out: \(dropped.joined(separator: ", "))")
        }
        guard status.mode.usesTransport else { return }

        if directive == nil {
            scheduleIdleClose()
            return
        }
        closeTask?.cancel()
        closeTask = nil
        if transport != nil {
            // While connecting, the post-connect check sends whatever is newest.
            if sessionOpen, let directive { push(directive) }
        } else if case .paused = status.phase {
            // Capped: waits for a manual resume. Stalled: reopens with the camera.
        } else if feedStalled {
            status.phase = .paused(.feedStalled)
        } else if status.phase != .connecting {
            status.phase = .connecting
            openWhenFrameReady()
        }
    }

    // MARK: Frames

    /// Every source frame passes through here while a transport is in use.
    func ingest(_ frame: CGImage) {
        sourceSize = CGSize(width: frame.width, height: frame.height)
        guard status.mode.usesTransport, status.directive != nil else { return }
        if encoder.currentFormat == nil {
            encoder.begin(format: .matching(width: frame.width, height: frame.height), sink: nil)
        }
        encoder.submit(frame)
        if status.phase == .connecting, transport == nil, !connecting {
            openWhenFrameReady()
        }
    }

    /// What the Stage should show for this source frame.
    func output(for original: CGImage) -> CGImage {
        guard let latestOutput, Date.now.timeIntervalSince(latestOutputAt) < policy.outputStaleAfter else {
            return original
        }
        return latestOutput
    }

    func feedDidStall() {
        feedStalled = true
        guard status.phase.isInSession || status.phase == .connecting else { return }
        closeTask?.cancel()
        let delay = policy.stallCloseDelay
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.feedStalled else { return }
            await self.closeSession(reason: "No camera frames")
            self.status.phase = .paused(.feedStalled)
        }
    }

    func feedDidResume() {
        feedStalled = false
        if case .paused(.feedStalled) = status.phase, status.directive != nil {
            log("Camera is back; reopening")
            status.phase = .connecting
            openWhenFrameReady()
        } else if status.phase.isInSession {
            closeTask?.cancel()
            closeTask = nil
        }
    }

    // MARK: Manual controls (console)

    /// After a session cap (or a failure), open a fresh session.
    func resume() {
        guard status.directive != nil, status.mode.usesTransport else { return }
        if status.phase == .paused(.launchCap) { return }
        retries = 0
        status.phase = .connecting
        openWhenFrameReady()
    }

    func endSession() async {
        await closeSession(reason: "Ended by hand")
        status.phase = .idle
    }

    func resendPrompt() {
        guard let directive = status.directive, transport != nil else { return }
        appliedDirective = nil
        push(directive)
    }

    /// Rehearsal only: drop the link for a moment.
    func simulateDrop() {
        (transport as? RehearsalLucyTransport)?.simulateDrop()
    }

    // MARK: Opening and closing

    private func openWhenFrameReady() {
        guard transport == nil, !connecting, let directive = status.directive else { return }
        guard !(status.mode == .live && status.liveSeconds >= policy.liveLaunchCapSeconds) else {
            status.phase = .paused(.launchCap)
            return
        }
        // The uplink must carry a frame before it can publish; wait for the next one.
        guard let firstFrame = encoder.latestFrame, let format = encoder.currentFormat else { return }
        connecting = true
        let mode = status.mode
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { connecting = false }
            do {
                let transport = try await makeTransport(mode)
                guard status.mode == mode, status.directive != nil else { return }
                if let rehearsal = transport as? RehearsalLucyTransport {
                    rehearsal.trackedRegions = { [weak self] in self?.trackedRegions?() ?? [] }
                    rehearsal.sourceSize = { [weak self] in self?.sourceSize }
                }
                transport.onEvent = { [weak self, weak transport] event in
                    guard let self, let transport, self.transport === transport else { return }
                    self.handle(event)
                }
                self.transport = transport
                status.promptState = .sending
                log("Opening \(mode.displayName) session · \(format.width)×\(format.height)")
                // Frames flow from here on; the session sees them as soon as it's up.
                encoder.begin(format: format, sink: { [weak transport] frame in transport?.send(frame) })
                try await transport.connect(format: format, directive: directive, firstFrame: firstFrame)
                guard self.transport === transport else { return }
                sessionOpen = true
                appliedDirective = directive
                status.promptState = .applied(at: .now)
                status.promptsApplied += 1
                status.sessionsOpened += 1
                status.sessionSeconds = 0
                liveSecondsBeforeSession = status.liveSeconds
                retries = 0
                log("Session open; prompt applied (\(directive.text.count) chars)")
                startMeters()
                // Anything cast while connecting goes out now.
                if let latest = status.directive, latest.differsForLucy(from: directive) {
                    push(latest)
                }
            } catch {
                await failSession(error.localizedDescription)
            }
        }
    }

    private func scheduleIdleClose() {
        guard transport != nil || status.phase == .connecting else {
            status.phase = .idle
            return
        }
        closeTask?.cancel()
        let delay = policy.idleCloseDelay
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.status.directive == nil else { return }
            await self.closeSession(reason: "Nothing cast")
            self.status.phase = .idle
        }
    }

    private func closeSession(reason: String) async {
        closeTask?.cancel()
        closeTask = nil
        meterTask?.cancel()
        meterTask = nil
        // The next session re-reads the source's shape.
        encoder.reset()
        sessionOpen = false
        pendingDirective = nil
        appliedDirective = nil
        latestOutput = nil
        let transport = self.transport
        self.transport = nil
        if let transport {
            transport.onEvent = nil
            await transport.disconnect()
            log("Session closed · \(reason)")
        }
        status.uplinkFPS = 0
        status.downlinkFPS = 0
        if status.phase.isInSession { status.phase = .idle }
    }

    private func failSession(_ reason: String) async {
        log("Failed: \(reason)")
        await closeSession(reason: "Error")
        status.promptState = .failed(reason)
        guard status.directive != nil, !feedStalled, retries < policy.maxRetries else {
            status.phase = .failed(reason)
            return
        }
        retries += 1
        status.phase = .reconnecting
        log("Retrying (\(retries)/\(policy.maxRetries))")
        try? await Task.sleep(for: policy.retryDelay)
        guard status.phase == .reconnecting else { return }
        status.phase = .connecting
        openWhenFrameReady()
    }

    // MARK: Prompt updates (serialized, newest wins)

    private func push(_ directive: LucyDirective) {
        guard directive.differsForLucy(from: appliedDirective) else { return }
        pendingDirective = directive
        guard !applying else { return }
        applying = true
        Task { @MainActor in
            defer { applying = false }
            while let next = pendingDirective, let transport, sessionOpen {
                pendingDirective = nil
                status.promptState = .sending
                do {
                    try await transport.apply(next)
                    guard self.transport === transport else { return }
                    appliedDirective = next
                    status.promptState = .applied(at: .now)
                    status.promptsApplied += 1
                    log("Prompt applied (\(next.text.count) chars, \(next.parts.count) cast\(next.parts.count == 1 ? "" : "s"))")
                } catch LucyTransportError.superseded {
                    continue
                } catch {
                    guard self.transport === transport else { return }
                    status.promptState = .failed(error.localizedDescription)
                    log("Prompt failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Transport events

    private func handle(_ event: LucyTransportEvent) {
        switch event {
        case .connected:
            if status.phase != .streaming { status.phase = .streaming }
        case .queued(let position):
            status.phase = .queued(position: position)
        case .reconnecting:
            status.phase = .reconnecting
            log("Link dropped; reconnecting")
        case .ended(let reason):
            Task { @MainActor in await failSession(reason) }
        case .generatedSeconds(let seconds):
            status.sessionSeconds = seconds
            if status.mode == .live {
                status.liveSeconds = liveSecondsBeforeSession + seconds
            }
            enforceCaps()
        case .output(let image):
            latestOutput = image
            latestOutputAt = .now
            downlinkCount += 1
            if status.phase == .connecting { status.phase = .streaming }
        }
    }

    private func enforceCaps() {
        let reason: LucyPauseReason
        if status.mode == .live, status.liveSeconds >= policy.liveLaunchCapSeconds {
            reason = .launchCap
            log("Live spending cap reached (\(Int(policy.liveLaunchCapSeconds)) s this launch)")
        } else if status.sessionSeconds >= policy.sessionCapSeconds {
            reason = .sessionCap
            log("Session cap reached (\(Int(policy.sessionCapSeconds)) s)")
        } else {
            return
        }
        // Stop listening first so later ticks can't trigger this twice.
        transport?.onEvent = nil
        status.phase = .paused(reason)
        Task { @MainActor in
            await closeSession(reason: reason.label)
        }
    }

    private func startMeters() {
        meterTask?.cancel()
        _ = encoder.drainCount()
        downlinkCount = 0
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.status.uplinkFPS = Double(self.encoder.drainCount())
                self.status.downlinkFPS = Double(self.downlinkCount)
                self.downlinkCount = 0
            }
        }
    }

    private func log(_ message: String) {
        print("[Lucy] \(message)")
        status.log.insert(LucyLogEntry(at: .now, message: message), at: 0)
        if status.log.count > LucyLinkStatus.logLimit {
            status.log.removeLast(status.log.count - LucyLinkStatus.logLimit)
        }
    }
}
