//
//  LucyPipelineTests.swift
//  MorphoTests
//
//  The Lucy link without Lucy: the one-prompt scene composer (every cast
//  stays in the prompt), outcome phrasing, token payloads, uplink framing,
//  and the director's session policy against a recording transport.
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Testing
import UIKit
@testable import Morpho

// MARK: - Fixtures

private func augmentation(_ label: String, prompt: String, speech: String) -> TargetedAugmentation {
    TargetedAugmentation(
        target: AugmentationTarget(source: .manual, label: label, boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3), frameSize: CGSize(width: 720, height: 1280)),
        rawSpeech: speech,
        spec: LucyPromptSpec(editType: .replace, prompt: prompt, confidence: 0.8)
    )
}

private let mugCast = augmentation(
    "Mug",
    prompt: "Replace the white ceramic mug with a golden trophy cup at the same scale. Keep everything else in the scene unchanged.",
    speech: "make this a golden trophy"
)
private let hoodieCast = augmentation(
    "Person",
    prompt: "Change the gray hoodie on the man to a red leather jacket, moving with his body. Keep everything else in the scene unchanged.",
    speech: "give him a red leather jacket"
)

private func frame(width: Int = 360, height: Int = 640) -> CGImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
        // A lit scene, so black Lucy output reads as blank.
        UIColor.lightGray.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }.cgImage!
}

/// Polls until `condition` holds (the director works in tasks and the encoder on its own queue).
@MainActor
private func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// Records what the director asks of Lucy.
@MainActor
private final class RecordingTransport: LucyTransport {
    var onEvent: ((LucyTransportEvent) -> Void)?
    var connectedWith: LucyDirective?
    var connectedFormat: LucyStreamFormat?
    var applied: [LucyDirective] = []
    var disconnects = 0
    var failConnect = false
    /// Refuse any prompt containing this text, the way Lucy refuses copyrighted IP.
    var refuse: String?

    private func check(_ directive: LucyDirective) throws {
        if let refuse, directive.text.localizedCaseInsensitiveContains(refuse) {
            throw LucyTransportError.rejected("Server error: Content contains copyrighted IP that cannot be generated")
        }
    }

    func connect(format: LucyStreamFormat, directive: LucyDirective, firstFrame: CVPixelBuffer) async throws {
        if failConnect { throw LucyTransportError.rejected("nope") }
        try check(directive)
        connectedWith = directive
        connectedFormat = format
        onEvent?(.connected)
    }

    nonisolated func send(_ frame: CVPixelBuffer) {}

    func apply(_ directive: LucyDirective) async throws {
        try await Task.sleep(for: .milliseconds(10))
        try check(directive)
        applied.append(directive)
    }

    func disconnect() async {
        disconnects += 1
    }
}

/// A private settings store per director, so tests never touch the app's.
private func scratchDefaults() -> UserDefaults {
    let name = "LucyPipelineTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
private func makeDirector(mode: LucyLinkMode = .rehearsal, defaults: UserDefaults = scratchDefaults(), refuse: String? = nil) async -> (SessionModel, LucyDirector, () -> [RecordingTransport]) {
    let session = SessionModel()
    var made: [RecordingTransport] = []
    let director = LucyDirector(session: session, defaults: defaults) { _ in
        let transport = RecordingTransport()
        transport.refuse = refuse
        made.append(transport)
        return transport
    }
    director.policy.idleCloseDelay = .milliseconds(50)
    director.policy.stallCloseDelay = .milliseconds(50)
    director.policy.retryDelay = .milliseconds(20)
    director.recordingDidChange(true)
    if mode != .simulated {
        await director.setMode(mode)
    }
    return (session, director, { made })
}

/// Feeds frames until the director has opened a session (or gives up).
@MainActor
private func pump(_ director: LucyDirector, until condition: () -> Bool) async -> Bool {
    let image = frame()
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        director.ingest(image)
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

// MARK: - Scene composer

@MainActor
struct LucySceneComposerTests {
    @Test func nothingCastMeansNoDirective() {
        #expect(LucySceneComposer.directive(sceneCast: nil, augmentations: [], referenceImageData: nil, enrich: true) == nil)
    }

    @Test func aSingleCastPassesThroughVerbatim() throws {
        let directive = try #require(LucySceneComposer.directive(sceneCast: nil, augmentations: [mugCast], referenceImageData: nil, enrich: true))
        #expect(directive.text == mugCast.spec.prompt)
        #expect(directive.enrich)
    }

    @Test func everyAugmentationStaysInThePrompt() throws {
        // Newest first, as the session stores them.
        let directive = try #require(LucySceneComposer.directive(sceneCast: nil, augmentations: [hoodieCast, mugCast], referenceImageData: nil, enrich: true))
        #expect(directive.text.contains("golden trophy"))
        #expect(directive.text.contains("red leather jacket"))
        // One shared keep-clause, at the end.
        #expect(directive.text.components(separatedBy: "Keep everything else").count == 2)
        #expect(directive.text.hasSuffix(LucySceneComposer.keepClause))
        // Read in cast order: the mug came first.
        let mug = try #require(directive.text.range(of: "golden trophy"))
        let jacket = try #require(directive.text.range(of: "red leather jacket"))
        #expect(mug.lowerBound < jacket.lowerBound)
        #expect(directive.text.count <= LucyPromptSpec.maxLength)
    }

    @Test func aSceneRestyleLeadsAndDropsTheKeepClause() throws {
        let noir = Realm.realm(withID: "film-noir")!.promptSpec
        let directive = try #require(LucySceneComposer.directive(sceneCast: noir, augmentations: [mugCast], referenceImageData: nil, enrich: true))
        #expect(directive.text.hasPrefix("Transform the entire scene into high-contrast black-and-white film noir"))
        #expect(directive.text.contains("golden trophy"))
        #expect(!directive.text.contains(LucySceneComposer.keepClause))
    }

    @Test func overBudgetCompactsThenDropsTheOldest() throws {
        let long = String(repeating: "Wrap the object in shimmering gold foil with fine embossed filigree. ", count: 4)
        let casts = (0..<5).map { augmentation("Thing \($0)", prompt: "Change thing \($0) to gold. " + long, speech: "gold \($0)") }
        let directive = try #require(LucySceneComposer.directive(sceneCast: nil, augmentations: casts, referenceImageData: nil, enrich: true, budget: 120))
        #expect(directive.text.count <= 120)
        // The newest cast always survives; the oldest go first.
        #expect(directive.text.contains("thing 0"))
        #expect(!directive.droppedTitles.isEmpty)
        #expect(directive.parts.first?.kind == .targeted(casts[0].id))
    }

    @Test func onlyLucyRelevantChangesCount() throws {
        let a = try #require(LucySceneComposer.directive(sceneCast: nil, augmentations: [mugCast], referenceImageData: nil, enrich: true))
        var b = a
        b.parts = []
        #expect(!b.differsForLucy(from: a))
        b.enrich = false
        #expect(b.differsForLucy(from: a))
    }
}

// MARK: - Outcome phrasing

@MainActor
struct LucyOutcomePhrasingTests {
    @Test func prohibitionsBecomeKeeps() {
        let text = LucyPromptSpec.outcomePhrased("Replace the mug with a trophy. Don't change the person's face.")
        #expect(text == "Replace the mug with a trophy. Keep the person's face unchanged.")
    }

    @Test func dictatedApostrophesToo() {
        #expect(LucyPromptSpec.outcomePhrased("Don\u{2019}t alter the background.") == "Keep the background unchanged.")
    }

    @Test func otherNegativeSentencesAreDropped() {
        #expect(LucyPromptSpec.outcomePhrased("Add a hat to the man. No sunglasses.") == "Add a hat to the man.")
    }

    @Test func sanitizedAppliesIt() {
        let spec = LucyPromptSpec(editType: .add, prompt: "Never modify the table. Add a lamp to the table.", confidence: 1).sanitized()
        #expect(spec.prompt == "Keep the table unchanged. Add a lamp to the table.")
    }
}

// MARK: - Tokens

@MainActor
struct TokenPayloadTests {
    @Test func decartClientTokenShape() throws {
        let json = #"{"apiKey":"ek_123","expiresAt":"2026-09-26T20:00:00.000Z"}"#
        let payload = try JSONDecoder().decode(TokenPayload.self, from: Data(json.utf8))
        #expect(payload.value == "ek_123")
        #expect(payload.expiry(now: .now) == ISO8601DateFormatter().date(from: "2026-09-26T20:00:00Z"))
    }

    @Test func edgeFunctionShape() throws {
        let json = #"{"token":"ek_456","expires_in":900}"#
        let payload = try JSONDecoder().decode(TokenPayload.self, from: Data(json.utf8))
        let now = Date.now
        #expect(payload.value == "ek_456")
        #expect(payload.expiry(now: now) == now.addingTimeInterval(900))
    }

    @Test func unknownLifetimeIsDecartsDefault() throws {
        let payload = try JSONDecoder().decode(TokenPayload.self, from: Data(#"{"apiKey":"ek"}"#.utf8))
        let now = Date.now
        #expect(payload.expiry(now: now) == now.addingTimeInterval(60))
    }
}

// MARK: - Uplink

@MainActor
struct LucyUplinkTests {
    @Test func formatFollowsTheSourceOrientation() {
        #expect(LucyStreamFormat.matching(width: 1920, height: 1080) == .landscape)
        #expect(LucyStreamFormat.matching(width: 1080, height: 1920) == .portrait)
    }

    @Test func aspectFillCoversTheWholeFrame() {
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let filled = LucyFrameEncoder.aspectFill(source, width: 720, height: 1280)
        #expect(filled.extent == CGRect(x: 0, y: 0, width: 720, height: 1280))
    }

    @Test func encoderProducesLucySizedBuffers() async {
        let encoder = LucyFrameEncoder()
        encoder.begin(format: .portrait, sink: nil)
        encoder.submit(frame())
        let ready = await eventually { encoder.latestFrame != nil }
        #expect(ready)
        if let buffer = encoder.latestFrame {
            #expect(CVPixelBufferGetWidth(buffer) == 720)
            #expect(CVPixelBufferGetHeight(buffer) == 1280)
        }
    }
}

// MARK: - Director policy

@MainActor
struct LucyDirectorTests {
    @Test func simulatedModeNeverOpensATransport() async {
        let (session, director, made) = await makeDirector(mode: .simulated)
        session.augmentations = [mugCast]
        director.sceneDidChange()
        for _ in 0..<10 { director.ingest(frame()) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(made().isEmpty)
        #expect(session.lucy.directive != nil)
        #expect(!director.drivesFeed)
    }

    @Test func nothingOpensUntilSomethingIsCast() async {
        let (session, director, made) = await makeDirector()
        for _ in 0..<10 { director.ingest(frame()) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(made().isEmpty)
        #expect(session.lucy.phase == .idle)
    }

    @Test func firstCastOpensWithTheSceneInPlace() async throws {
        let (session, director, made) = await makeDirector()
        session.augmentations = [mugCast]
        director.sceneDidChange()
        #expect(session.lucy.phase == .connecting)
        let opened = await pump(director) { made().first?.connectedWith != nil }
        #expect(opened)
        let transport = try #require(made().first)
        #expect(transport.connectedWith?.text == mugCast.spec.prompt)
        #expect(transport.connectedFormat == .portrait)
        #expect(session.lucy.phase == .streaming)
        #expect(director.drivesFeed)
    }

    @Test func aNewCastKeepsTheEarlierOnesApplied() async throws {
        let (session, director, made) = await makeDirector()
        session.augmentations = [mugCast]
        director.sceneDidChange()
        _ = await pump(director) { made().first?.connectedWith != nil }
        let transport = try #require(made().first)

        session.augmentations = [hoodieCast, mugCast]
        director.sceneDidChange()
        let updated = await eventually { !transport.applied.isEmpty }
        #expect(updated)
        let prompt = try #require(transport.applied.last?.text)
        #expect(prompt.contains("golden trophy"))
        #expect(prompt.contains("red leather jacket"))
        #expect(made().count == 1)
    }

    @Test func clearingEverythingClosesTheSession() async throws {
        let (session, director, made) = await makeDirector()
        session.augmentations = [mugCast]
        director.sceneDidChange()
        _ = await pump(director) { made().first?.connectedWith != nil }
        let transport = try #require(made().first)

        session.augmentations = []
        director.sceneDidChange()
        let closed = await eventually { transport.disconnects == 1 }
        #expect(closed)
        #expect(session.lucy.phase == .idle)
        #expect(!director.drivesFeed)
    }

    @Test func aStalledFeedPausesAndResumes() async throws {
        let (session, director, made) = await makeDirector()
        session.augmentations = [mugCast]
        director.sceneDidChange()
        _ = await pump(director) { made().first?.connectedWith != nil }

        director.feedDidStall()
        let paused = await eventually { session.lucy.phase == .paused(.feedStalled) }
        #expect(paused)
        #expect(made().first?.disconnects == 1)

        director.feedDidResume()
        let reopened = await pump(director) { made().count == 2 && made()[1].connectedWith != nil }
        #expect(reopened)
    }

    @Test func theSessionCapEndsTheSession() async throws {
        let (session, director, made) = await makeDirector()
        director.policy.sessionCapSeconds = 5
        session.augmentations = [mugCast]
        director.sceneDidChange()
        _ = await pump(director) { made().first?.connectedWith != nil }
        let transport = try #require(made().first)

        transport.onEvent?(.generatedSeconds(6))
        #expect(session.lucy.phase == .paused(.sessionCap))
        let closed = await eventually { transport.disconnects == 1 }
        #expect(closed)

        // Resuming opens a fresh session.
        director.resume()
        let reopened = await pump(director) { made().count == 2 }
        #expect(reopened)
    }

    @Test func liveStopsAtTheLaunchCapAndIsNeverRemembered() async throws {
        let defaults = scratchDefaults()
        let (session, director, made) = await makeDirector(mode: .live, defaults: defaults)
        #expect(defaults.string(forKey: LucyDirector.modeDefaultsKey) == nil)
        director.policy.liveLaunchCapSeconds = 10
        session.augmentations = [mugCast]
        director.sceneDidChange()
        _ = await pump(director) { made().first?.connectedWith != nil }
        let transport = try #require(made().first)

        transport.onEvent?(.generatedSeconds(4))
        #expect(session.lucy.liveSeconds == 4)
        transport.onEvent?(.generatedSeconds(11))
        #expect(session.lucy.phase == .paused(.launchCap))
        let closed = await eventually { transport.disconnects == 1 }
        #expect(closed)

        // A new cast doesn't reopen a capped live link.
        session.augmentations = [hoodieCast, mugCast]
        director.sceneDidChange()
        for _ in 0..<5 { director.ingest(frame()) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(made().count == 1)
        #expect(session.lucy.estimatedLiveCost == 11 * LucyLinkStatus.dollarsPerSecond)
    }

    @Test func freeModesAreRemembered() async {
        let defaults = scratchDefaults()
        _ = await makeDirector(mode: .rehearsal, defaults: defaults)
        #expect(defaults.string(forKey: LucyDirector.modeDefaultsKey) == "rehearsal")
        // And a new launch comes back in it.
        let session = SessionModel()
        _ = LucyDirector(session: session, defaults: defaults) { _ in RecordingTransport() }
        #expect(session.lucy.mode == .rehearsal)
    }

    @Test func aFailedConnectRetriesThenGivesUp() async {
        let session = SessionModel()
        var attempts = 0
        let director = LucyDirector(session: session, defaults: scratchDefaults()) { _ in
            attempts += 1
            let transport = RecordingTransport()
            transport.failConnect = true
            return transport
        }
        director.policy.retryDelay = .milliseconds(10)
        director.recordingDidChange(true)
        await director.setMode(.rehearsal)
        session.augmentations = [mugCast]
        director.sceneDidChange()
        let failed = await pump(director) {
            if case .failed = session.lucy.phase { return true }
            return false
        }
        #expect(failed)
        #expect(attempts == 1 + director.policy.maxRetries)
    }

    @Test func stoppingRecordClosesTheSessionAndRecordBringsItBack() async throws {
        let (session, director, made) = await makeDirector()
        session.augmentations = [mugCast]
        director.sceneDidChange()
        _ = await pump(director) { made().first?.connectedWith != nil }
        let first = try #require(made().first)

        director.recordingDidChange(false)
        #expect(session.lucy.phase == .paused(.notRecording))
        #expect(!director.drivesFeed)
        let closed = await eventually { first.disconnects == 1 }
        #expect(closed)

        // A cast while not recording waits for Record.
        session.augmentations = [hoodieCast, mugCast]
        director.sceneDidChange()
        for _ in 0..<5 { director.ingest(frame()) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(made().count == 1)

        director.recordingDidChange(true)
        let reopened = await pump(director) { made().count == 2 && made()[1].connectedWith != nil }
        #expect(reopened)
        #expect(made()[1].connectedWith?.text.contains("red leather jacket") == true)
    }

    @Test func nothingOpensBeforeRecordIsPressed() async {
        let session = SessionModel()
        var made = 0
        let director = LucyDirector(session: session, defaults: scratchDefaults()) { _ in
            made += 1
            return RecordingTransport()
        }
        await director.setMode(.rehearsal)
        session.augmentations = [mugCast]
        director.sceneDidChange()
        for _ in 0..<10 { director.ingest(frame()) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(made == 0)
        #expect(session.lucy.phase == .paused(.notRecording))
    }

    @Test func blackWarmUpFramesNeverReachTheStage() async throws {
        let (session, director, made) = await makeDirector()
        session.augmentations = [mugCast]
        director.sceneDidChange()
        _ = await pump(director) { made().first?.connectedWith != nil }
        let transport = try #require(made().first)
        // The encoder has measured the (light gray) camera by now.
        _ = await pump(director) { director.encoder.latestLuma != nil }

        let camera = frame()
        let black = frame(width: 8, height: 8)
        transport.onEvent?(.output(black, luma: 0.01))
        #expect(director.output(for: camera) === camera)

        let edited = frame(width: 16, height: 16)
        transport.onEvent?(.output(edited, luma: 0.5))
        #expect(director.output(for: camera) === edited)
        _ = session
    }

    @Test func aDarkSceneKeepsItsDarkOutput() {
        #expect(LucyFrameProbe.isBlank(outputLuma: 0.01, sourceLuma: 0.6))
        #expect(!LucyFrameProbe.isBlank(outputLuma: 0.01, sourceLuma: 0.05))
        #expect(!LucyFrameProbe.isBlank(outputLuma: 0.3, sourceLuma: 0.6))
    }

    @Test func failuresAreClassified() {
        #expect(LucyFailureKind.classify("Server error: Content contains copyrighted IP that cannot be generated") == .contentRejected)
        #expect(LucyFailureKind.classify("401 Unauthorized") == .unauthorized)
        #expect(LucyFailureKind.classify("Network error(Timed out)") == .transient)
    }

    @Test func aRefusedFirstCastIsRemovedWithoutRetrying() async {
        let (session, director, made) = await makeDirector(refuse: "trophy")
        session.augmentations = [mugCast]
        director.sceneDidChange()
        let removed = await pump(director) { session.augmentations.isEmpty }
        #expect(removed)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(made().count == 1)
        #expect(session.lucy.phase == .idle)
        #expect(session.lucy.notice?.contains("copyrighted") == true)
    }

    @Test func aRefusedNewCastLeavesTheOthersApplied() async throws {
        let (session, director, made) = await makeDirector(refuse: "leather")
        session.augmentations = [mugCast]
        director.sceneDidChange()
        _ = await pump(director) { made().first?.connectedWith != nil }
        let transport = try #require(made().first)

        session.augmentations = [hoodieCast, mugCast]
        director.sceneDidChange()
        let removed = await eventually { session.augmentations.map(\.id) == [mugCast.id] }
        #expect(removed)
        // Same session, still streaming the mug.
        #expect(made().count == 1)
        #expect(transport.disconnects == 0)
        #expect(session.lucy.directive?.text == mugCast.spec.prompt)
    }
}
