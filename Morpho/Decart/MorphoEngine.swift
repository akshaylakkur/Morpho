//
//  MorphoEngine.swift
//  Morpho
//
//  The pipeline coordinator (spec §10): owns the frame source, the Lucy link
//  (LucyDirector: simulated, rehearsal, or live Lucy 2.5), the Loopcast ring
//  buffer, and the recorder. Publishes the two live frames the Stage
//  renders; all session *state* lives in SessionModel.
//

import CoreImage
import Observation
import SwiftUI

@Observable
final class MorphoEngine {
    // Frames are high-frequency; they live here (not in SessionModel) so the
    // rest of the UI doesn't re-evaluate 30× a second.
    private(set) var originalFrame: CGImage?
    private(set) var transformedFrame: CGImage?

    let session: SessionModel
    let credentials: MorphoCredentials
    let tokenService: TokenService
    let recorder = Recorder()
    /// Playback of Reel takes on the Stage (spec §9).
    let replay = ReplayController()
    /// The Deck's autodetection layer: on-device segmentation of the live feed.
    /// Driven by the Deck (it runs only while the controller is on screen).
    let sceneSegmenter = SceneSegmenter()

    // Feed liveness (spec §7) is nothing more than "a frame arrived recently".
    // Pause or Disconnect on the phone, a pulled cable, or a stopped relay all
    // look the same from here: frames stop.
    private(set) var feedIsLive = false
    private var lastFrameAt = Date.distantPast
    private var watchdogTask: Task<Void, Never>?
    static let feedStallTimeout: TimeInterval = 1.2

    private var source: VideoFrameSource?
    private let ciContext = CIContext()
    private var startedAt = Date.now

    /// The Lucy link: every cast becomes (part of) its prompt, and while a
    /// transport is in use, source frames go up and Lucy's frames come back.
    @ObservationIgnored private(set) var lucy: LucyDirector!

    // MARK: Click-and-augment (targeted casting)
    /// The Deck's viewfinder freezes on this frame while a target is being spoken to.
    private(set) var heldFrame: CGImage?
    /// The regions as they were on the held frame, so the overlay freezes with it.
    private(set) var heldSegmentation: SceneSegmentation?
    /// Tight crop of the locked target, for the on-device compile.
    private(set) var heldCrop: CGImage?
    /// Where each augmentation's target is right now; per-frame state, not observed.
    @ObservationIgnored private var tracking: [UUID: TrackedShape] = [:]
    /// A lost region is rebound to whatever region overlaps its last shape this much.
    static let rebindIoU: CGFloat = 0.4

    private struct TrackedShape {
        var regionID: Int?
        var box: CGRect
        var outline: [CGPoint]
    }

    // Loopcast ring buffer: ~3 seconds of transformed frames at ~15fps (spec §7).
    private(set) var loopcastBuffer: [CGImage] = []
    private var frameCounter = 0
    static let loopcastCapacity = 45
    static let loopcastFPS = 15

    init(session: SessionModel, credentials: MorphoCredentials = .load()) {
        self.session = session
        self.credentials = credentials
        let tokenService = TokenService(credentials: credentials)
        self.tokenService = tokenService
        session.reel = ReelStore.load()
        lucy = LucyDirector(session: session) { mode in
            try await Self.makeTransport(for: mode, credentials: credentials, tokenService: tokenService)
        }
        lucy.trackedRegions = { [weak self] in self?.trackedRegionsForLucy() ?? [] }
    }

    /// The backend for each link mode. Live needs the package and a credential.
    private static func makeTransport(
        for mode: LucyLinkMode,
        credentials: MorphoCredentials,
        tokenService: TokenService
    ) async throws -> LucyTransport {
        switch mode {
        case .simulated:
            throw LucyTransportError.notAvailable("The simulated look doesn't use a transport")
        case .rehearsal:
            return RehearsalLucyTransport()
        case .live:
            #if canImport(DecartSDK)
            guard credentials.canReachDecart else {
                throw LucyTransportError.notAvailable("No Decart credential in Secrets.plist")
            }
            // Minted per session: Decart bakes the key into the signaling URL.
            return DecartLucyTransport(apiKey: try await tokenService.currentToken())
            #else
            throw LucyTransportError.notAvailable("The DecartSDK package isn't linked")
            #endif
        }
    }

    /// Where each targeted cast's thing is now, for the rehearsal backend.
    private func trackedRegionsForLucy() -> [RehearsalLucyTransport.TrackedRegion] {
        session.augmentations.reversed().map { augmentation in
            RehearsalLucyTransport.TrackedRegion(
                box: tracking[augmentation.id]?.box ?? augmentation.target.boundingBox,
                title: augmentation.shortTitle
            )
        }
    }

    /// Whether Lucy should be up at all is the director's call; the engine just reports changes.
    private func sceneDidChange() {
        lucy.sceneDidChange()
    }

    // MARK: Lifecycle

    /// Connect on entering any camera mode (spec §6).
    func start() async {
        guard session.connection == .disconnected else { return }
        session.connection = .connecting
        preferTetherIfPresent()
        startWatchdog()

        // The feed itself is local; Lucy sessions open only once something is
        // cast (LucyDirector), so launching never starts a billed session.
        // A brief theatrical tune-in, then live.
        try? await Task.sleep(for: .milliseconds(900))
        session.connection = .connected
        startSource()
    }

    func stop() {
        autoTetherTask?.cancel()
        watchdogTask?.cancel()
        source?.stop()
        source = nil
        session.connection = .disconnected
    }

    // MARK: Source selection (spec §6.1 tier switch)

    func availableSources() -> [VideoSourceKind] {
        var kinds: [VideoSourceKind] = [.bundledClip]
        if CameraFrameSource.isAvailable { kinds.append(.localCamera) }
        if TetherFrameSource.isSupported { kinds.append(.tether) }
        return kinds
    }

    func selectSource(_ kind: VideoSourceKind) {
        guard availableSources().contains(kind) else { return }
        session.videoSource = kind
        if session.connection != .disconnected {
            startSource()
        }
    }

    private func startSource() {
        source?.stop()
        let next: VideoFrameSource
        switch session.videoSource {
        case .bundledClip:
            next = BundledClipSource.clipURL != nil ? BundledClipSource() : SyntheticClipSource()
        case .localCamera:
            let camera = CameraFrameSource()
            camera.usesFrontCamera = session.usesFrontCamera
            next = camera
        case .tether:
            // The USB-attached iPhone, relayed by Tools/MorphoTether on the Mac.
            next = TetherFrameSource()
        }
        source = next
        next.start { [weak self] frame in
            self?.ingest(frame)
        }

        if session.videoSource == .bundledClip {
            watchForTether()
        } else {
            autoTetherTask?.cancel()
        }
    }

    // MARK: Tether auto-selection (spec §6.1 tier 3)

    private var autoTetherTask: Task<Void, Never>?

    /// A running relay wins over the demo clip; the clip stays the fallback.
    private func preferTetherIfPresent() {
        if session.videoSource == .bundledClip, TetherFrameSource.isDiscoverable {
            session.videoSource = .tether
        }
    }

    /// While we're on the demo clip, watch for the relay coming up and hop to it.
    private func watchForTether() {
        autoTetherTask?.cancel()
        guard TetherFrameSource.isSupported else { return }
        autoTetherTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.session.videoSource == .bundledClip else { return }
                if TetherFrameSource.isDiscoverable {
                    self.selectSource(.tether)
                    return
                }
            }
        }
    }

    func flipCamera() {
        session.usesFrontCamera.toggle()
        if session.videoSource == .localCamera { startSource() }
    }

    // MARK: Frame path

    func ingest(_ frame: CGImage) {
        originalFrame = frame

        followTargets()
        // While a Lucy transport is in use the frame goes up, and what the
        // Stage shows is Lucy's latest (the untouched frame until it arrives).
        lucy.ingest(frame)
        let transformed: CGImage
        if lucy.drivesFeed {
            transformed = lucy.output(for: frame)
        } else if session.lucy.mode.usesTransport || !session.isRecording {
            // The overlay runs only while recording (and a paused Lucy shows the untouched feed).
            transformed = frame
        } else {
            transformed = simulateTransform(frame)
        }
        transformedFrame = transformed

        lastFrameAt = .now
        if !feedIsLive { feedDidResume() }

        frameCounter += 1
        if frameCounter % 2 == 0 { // ~15fps into the loopcast ring
            loopcastBuffer.append(transformed)
            if loopcastBuffer.count > Self.loopcastCapacity {
                loopcastBuffer.removeFirst()
            }
        }

        if session.isRecording {
            // The writer opens on the first real frame so it matches the feed's
            // size — Record can be pressed before the tether delivers anything.
            if !recorder.isWriting {
                recorder.begin(width: transformed.width, height: transformed.height)
            }
            recorder.append(transformed)
        }
    }

    private func simulateTransform(_ frame: CGImage) -> CGImage {
        // Targeted casts are staged for Lucy and not rendered locally: only a
        // Realm or a whole-scene incantation drives the simulation.
        guard session.lastCast != nil || session.activeRealm != nil else { return frame }
        let input = CIImage(cgImage: frame)
        let output = SimulatedLucy.transform(
            input,
            spec: session.lastCast,
            realmID: session.activeRealm?.id,
            time: Date.now.timeIntervalSince(startedAt)
        )
        return ciContext.createCGImage(output, from: input.extent) ?? frame
    }

    /// Keeps each staged cast attached to its thing: the tracked region when
    /// visible, a rebind to whatever region took its place, else its last
    /// known shape. Hand-drawn targets that matched no region stay put.
    private func followTargets() {
        guard !session.augmentations.isEmpty else { return }
        let regions = sceneSegmenter.current?.regions ?? []
        for augmentation in session.augmentations where augmentation.target.isDetected {
            var shape = tracking[augmentation.id] ?? TrackedShape(
                regionID: augmentation.target.regionID,
                box: augmentation.target.boundingBox,
                outline: augmentation.target.outline
            )
            if let id = shape.regionID, let region = regions.first(where: { $0.id == id }) {
                shape.box = region.boundingBox
                shape.outline = region.outline
            } else if let replacement = regions
                .map({ ($0, TargetGeometry.iou($0.boundingBox, shape.box)) })
                .filter({ $0.1 >= Self.rebindIoU })
                .max(by: { $0.1 < $1.1 })?.0 {
                shape.regionID = replacement.id
                shape.box = replacement.boundingBox
                shape.outline = replacement.outline
            }
            tracking[augmentation.id] = shape
        }
    }

    // MARK: Click-and-augment (targeted casting)

    /// Lock a detected region: hold the frame and crop the target out of it.
    func lockTarget(region: DetectedRegion) -> AugmentationTarget? {
        guard let frame = heldFrame ?? originalFrame else { return nil }
        return hold(
            frame: frame,
            source: .detected(regionID: region.id),
            label: region.label.isEmpty ? "Object" : region.label,
            box: region.boundingBox,
            outline: region.outline
        )
    }

    /// Lock a hand-drawn rectangle. It snaps to the detected region it mostly
    /// covers, so the augmentation can follow that region; otherwise it stays
    /// a fixed patch of the frame.
    func lockTarget(manualRect rect: CGRect, snappingTo regions: [DetectedRegion]) -> AugmentationTarget? {
        guard let frame = heldFrame ?? originalFrame, rect.width > 0.02, rect.height > 0.02 else { return nil }
        if let match = TargetGeometry.bestMatch(for: rect, in: regions) {
            return hold(
                frame: frame,
                source: .detected(regionID: match.id),
                label: match.label.isEmpty ? "Object" : match.label,
                box: match.boundingBox,
                outline: match.outline
            )
        }
        return hold(frame: frame, source: .manual, label: "Selection", box: rect, outline: [])
    }

    private func hold(frame: CGImage, source: TargetSource, label: String, box: CGRect, outline: [CGPoint]) -> AugmentationTarget? {
        let crops = TargetCropper.crops(from: frame, box: box)
        if heldFrame == nil {
            heldSegmentation = sceneSegmenter.current
        }
        heldFrame = frame
        heldCrop = crops?.tight
        return AugmentationTarget(
            source: source,
            label: label,
            boundingBox: box,
            outline: outline,
            frameSize: CGSize(width: frame.width, height: frame.height),
            cropData: crops?.tightJPEG,
            lucyImageData: crops?.lucyJPEG
        )
    }

    /// Let the viewfinder run again.
    func releaseTarget() {
        heldFrame = nil
        heldSegmentation = nil
        heldCrop = nil
    }

    /// The compiled augmentation lands on its target and follows it from here
    /// on. Live path: the target's `lucyBundle` becomes the next `setPrompt`.
    func applyAugmentation(target: AugmentationTarget, rawSpeech: String, spec: LucyPromptSpec) async {
        let augmentation = TargetedAugmentation(target: target, rawSpeech: rawSpeech, spec: spec.sanitized())
        session.recordAugmentation(augmentation)
        tracking[augmentation.id] = TrackedShape(regionID: target.regionID, box: target.boundingBox, outline: target.outline)
        let live = Set(session.augmentations.map(\.id))
        for id in tracking.keys where !live.contains(id) {
            tracking[id] = nil
        }
        releaseTarget()
        session.rerollSeedIfUnlocked()
        // Lucy's prompt now carries this cast alongside every other one in effect.
        sceneDidChange()
        await simulatedGenerationBeat()
    }

    func removeAugmentation(_ augmentation: TargetedAugmentation) {
        session.removeAugmentation(augmentation.id)
        tracking[augmentation.id] = nil
        sceneDidChange()
    }

    func clearAugmentations() {
        session.augmentations.removeAll()
        tracking.removeAll()
        sceneDidChange()
    }

    /// The orb's brief "Generating" beat when nothing real is generating.
    private func simulatedGenerationBeat() async {
        guard !session.lucy.mode.usesTransport else { return }
        session.connection = .generating
        try? await Task.sleep(for: .milliseconds(700))
        if session.connection == .generating {
            session.connection = .connected
        }
    }

    /// Region id → the augmentation riding it, following rebinds.
    func augmentationsByRegion() -> [Int: TargetedAugmentation] {
        var result: [Int: TargetedAugmentation] = [:]
        for augmentation in session.augmentations {
            if let id = tracking[augmentation.id]?.regionID ?? augmentation.target.regionID {
                result[id] = augmentation
            }
        }
        return result
    }

    // MARK: Casting

    /// Apply a compiled prompt to the session (spec §5 tail): guardrails, then
    /// setPrompt on the live manager or a simulated generation beat.
    func cast(rawSpeech: String, spec: LucyPromptSpec) async {
        let clean = spec.sanitized()
        session.recordCast(rawSpeech: rawSpeech, spec: clean)
        session.rerollSeedIfUnlocked()
        sceneDidChange()
        // Simulated warm-up: long enough for the transmutation sweep to land.
        await simulatedGenerationBeat()
    }

    func castRealm(_ realm: Realm) async {
        session.activeRealm = realm
        await cast(rawSpeech: realm.name, spec: realm.promptSpec)
    }

    /// Chips behave like toggles: tapping the active Realm again clears it.
    func toggleRealm(_ realm: Realm) {
        if session.activeRealm == realm {
            clearRealm()
        } else {
            Task { await castRealm(realm) }
        }
    }

    /// Back to the untouched feed: no Realm, no lingering incantation, no targeted casts.
    func clearRealm() {
        guard session.hasAnyCast else { return }
        session.activeRealm = nil
        session.lastCast = nil
        // Clearing the last cast closes the Lucy session (after a short grace).
        clearAugmentations()
        session.sweepTrigger += 1
    }

    func recast(_ incantation: Incantation) async {
        await cast(rawSpeech: incantation.rawSpeech, spec: incantation.spec)
    }

    // MARK: Recording & exports

    func toggleRecording() {
        exitReplay()
        // Record is also the curtain call (spec §7), and arms the Stage to
        // reopen by itself whenever the feed comes back.
        session.stageArmed = true
        if session.stagePhase == .curtain {
            openStage()
        }
        if session.isRecording {
            // Stop: the feed keeps showing, but from here on it counts for
            // nothing — the take is finalized and filed in the Reel (spec §9).
            session.isRecording = false
            let started = session.recordingStartedAt
            session.recordingStartedAt = nil
            let realmName = session.activeRealm?.name
            Task { @MainActor in
                guard let url = await recorder.finish(startedAt: started),
                      let clip = await ReelStore.ingest(recording: url, realmName: realmName)
                else { return }
                session.reel.insert(clip, at: 0)
                ReelStore.save(session.reel)
                session.lastExportURL = clip.url
            }
        } else {
            // The writer itself opens on the first frame (see ingest).
            session.recordingStartedAt = .now
            session.isRecording = true
        }
        // Lucy runs only while recording.
        lucy.recordingDidChange(session.isRecording)
    }

    // MARK: The reveal (spec §7)

    /// The butterfly flies off and the iris opens onto the feed.
    func openStage() {
        guard session.stagePhase == .curtain else { return }
        session.stagePhase = .opening
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Theme.stageRevealDuration))
            if session.stagePhase == .opening {
                session.stagePhase = .live
            }
        }
    }

    /// The reverse: the iris closes and the wings come home, so a feed that
    /// stopped never reads as a frozen frame.
    func closeStage() {
        guard session.stagePhase == .live else { return }
        session.stagePhase = .closing
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Theme.stageRevealDuration))
            guard session.stagePhase == .closing else { return }
            session.stagePhase = .curtain
            clearFrames()
            // The phone may have resumed while the wings were coming home.
            if feedIsLive, session.stageArmed { openStage() }
        }
    }

    // MARK: Feed liveness (spec §7)

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                if self.feedIsLive, Date.now.timeIntervalSince(self.lastFrameAt) > Self.feedStallTimeout {
                    self.feedDidStall()
                }
            }
        }
    }

    /// No frame for a while: the phone paused, disconnected, or the relay stopped.
    func feedDidStall() {
        feedIsLive = false
        lucy.feedDidStall()
        switch session.stagePhase {
        case .live:
            closeStage()
        case .curtain, .opening, .closing:
            clearFrames()
        }
    }

    /// Frames are flowing again; an armed Stage opens back up on its own.
    func feedDidResume() {
        feedIsLive = true
        lucy.feedDidResume()
        if session.stagePhase == .curtain, session.stageArmed {
            openStage()
        }
    }

    private func clearFrames() {
        originalFrame = nil
        transformedFrame = nil
        releaseTarget()
    }

    // MARK: Replay (spec §9)

    func enterReplay(_ clip: Clip) {
        replay.load(clip)
    }

    func exitReplay() {
        guard replay.isActive else { return }
        replay.exit()
    }

    func deleteClip(_ clip: Clip) {
        if replay.clip?.id == clip.id { replay.exit() }
        session.reel.removeAll { $0.id == clip.id }
        ReelStore.delete(clip)
        ReelStore.save(session.reel)
        if session.lastExportURL == clip.url { session.lastExportURL = nil }
    }

    func saveClipToPhotos(_ clip: Clip) async {
        guard await ReelStore.saveToPhotos(clip),
              let index = session.reel.firstIndex(where: { $0.id == clip.id })
        else { return }
        session.reel[index].savedToPhotos = true
        ReelStore.save(session.reel)
        replay.update(session.reel[index])
    }

    /// Loopcast (spec §7): the last ~3 seconds of transformed footage as a GIF.
    func exportLoopcast() async -> URL? {
        let frames = loopcastBuffer
        guard !frames.isEmpty else { return nil }
        let url = await Recorder.writeGIF(frames: frames, fps: Self.loopcastFPS)
        session.lastExportURL = url
        return url
    }

    /// "Stills from another world" (spec §9).
    func captureStill() -> URL? {
        guard let frame = transformedFrame else { return nil }
        let url = Recorder.writeStill(frame)
        session.lastExportURL = url
        return url
    }
}
