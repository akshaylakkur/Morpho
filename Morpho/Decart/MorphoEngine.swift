//
//  MorphoEngine.swift
//  Morpho
//
//  The pipeline coordinator (spec §10): owns the frame source, the Lucy
//  transform (real SDK when present + credentialed, simulated otherwise),
//  the Loopcast ring buffer, and the recorder. Publishes the two live frames
//  the Stage renders; all session *state* lives in SessionModel.
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

    /// Live-SDK context (DecartSDK manager etc.). Type-erased so this file
    /// compiles without the package; see DecartLive.swift.
    var liveContext: AnyObject?
    private(set) var isLive = false

    // Loopcast ring buffer: ~3 seconds of transformed frames at ~15fps (spec §7).
    private(set) var loopcastBuffer: [CGImage] = []
    private var frameCounter = 0
    static let loopcastCapacity = 45
    static let loopcastFPS = 15

    init(session: SessionModel, credentials: MorphoCredentials = .load()) {
        self.session = session
        self.credentials = credentials
        self.tokenService = TokenService(credentials: credentials)
        session.reel = ReelStore.load()
    }

    // MARK: Lifecycle

    /// Connect on entering any camera mode (spec §6).
    func start() async {
        guard session.connection == .disconnected else { return }
        session.connection = .connecting
        preferTetherIfPresent()
        startWatchdog()

        #if canImport(DecartSDK)
        if credentials.canReachDecart {
            if await connectLive() {
                isLive = true
                session.connection = .connected
                startSource()
                return
            }
        }
        #endif

        // Simulated Lucy: brief theatrical tune-in, then live.
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

    private func ingest(_ frame: CGImage) {
        originalFrame = frame

        let transformed = simulateTransform(frame)
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
        // When the real SDK drives the session, the transformed feed arrives
        // as a remote track and this local simulation is bypassed.
        guard !isLive else { return frame }
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

    // MARK: Casting

    /// Apply a compiled prompt to the session (spec §5 tail): guardrails, then
    /// setPrompt on the live manager or a simulated generation beat.
    func cast(rawSpeech: String, spec: LucyPromptSpec) async {
        let clean = spec.sanitized()
        session.recordCast(rawSpeech: rawSpeech, spec: clean)
        session.rerollSeedIfUnlocked()
        session.connection = .generating

        #if canImport(DecartSDK)
        if isLive {
            await setLivePrompt(clean)
            session.connection = .connected
            return
        }
        #endif

        // Simulated warm-up: long enough for the transmutation sweep to land.
        try? await Task.sleep(for: .milliseconds(700))
        if session.connection == .generating {
            session.connection = .connected
        }
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

    /// Back to the untouched feed: no Realm, no lingering incantation.
    func clearRealm() {
        guard session.activeRealm != nil || session.lastCast != nil else { return }
        session.activeRealm = nil
        session.lastCast = nil
        session.sweepTrigger += 1
        // Live path (DecartLive.swift): the SDK keeps its last prompt until a
        // new one lands, so a prompt reset joins that wiring when it goes live.
    }

    func recast(_ incantation: Incantation) async {
        await cast(rawSpeech: incantation.rawSpeech, spec: incantation.spec)
    }

    // MARK: Recording & exports

    func toggleRecording() {
        exitReplay()
        if session.isRecording {
            // Stop: the take is finalized and filed in the Reel (spec §9), and
            // the Stage returns to the resting butterfly it showed before
            // Record — disarmed, so it waits for the next Record to reopen.
            session.stageArmed = false
            if session.stagePhase == .opening { session.stagePhase = .live }
            closeStage()
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
            // Record is also the curtain call (spec §7), and arms the Stage to
            // reopen by itself whenever the feed comes back.
            session.stageArmed = true
            if session.stagePhase == .curtain {
                openStage()
            }
            // The writer itself opens on the first frame (see ingest).
            session.recordingStartedAt = .now
            session.isRecording = true
        }
    }

    // MARK: Dual-screen recording

    /// The source that was showing before a dual-screen take swapped in the
    /// live feed; restored when that take stops.
    private var sourceBeforeLiveTake: VideoSourceKind?

    /// Record on the dual screen: takes are shot from the live feed (the
    /// tethered iPhone in the simulator, the device camera on hardware),
    /// never the demo clip. Stopping puts the previous source back.
    func toggleLiveRecording() {
        if session.isRecording {
            toggleRecording()
            if let previous = sourceBeforeLiveTake {
                sourceBeforeLiveTake = nil
                selectSource(previous)
            }
            return
        }

        let live: VideoSourceKind? = if CameraFrameSource.isAvailable {
            .localCamera
        } else if TetherFrameSource.isSupported {
            .tether
        } else {
            nil
        }
        if let live, session.videoSource != live {
            sourceBeforeLiveTake = session.videoSource
            selectSource(live)
        }
        toggleRecording()
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
        if session.stagePhase == .curtain, session.stageArmed {
            openStage()
        }
    }

    private func clearFrames() {
        originalFrame = nil
        transformedFrame = nil
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
