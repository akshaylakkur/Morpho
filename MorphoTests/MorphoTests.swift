//
//  MorphoTests.swift
//  MorphoTests
//

import CoreGraphics
import Foundation
import Testing
@testable import Morpho

// MARK: Lucy guardrails (spec §5)

struct GuardrailTests {
    @Test func longPromptsAreClampedOnSentenceBoundary() {
        let sentence = "Change the background to a field of tall silver grass. "
        let spec = LucyPromptSpec(
            editType: .background,
            prompt: String(repeating: sentence, count: 30),
            confidence: 1
        ).sanitized()
        #expect(spec.prompt.count <= LucyPromptSpec.maxLength)
        #expect(spec.prompt.hasSuffix("."))
    }

    @Test func negativeOpenersAreRewrittenAsOutcomes() {
        let spec = LucyPromptSpec(
            editType: .attribute,
            prompt: "don't change the face but make the jacket red",
            confidence: 1
        ).sanitized()
        #expect(!spec.prompt.lowercased().hasPrefix("don't"))
        #expect(spec.prompt.contains("Keep the scene unchanged except"))
    }

    @Test func cleanPromptPassesThroughUnchanged() {
        let prompt = "Change the jacket to glossy red leather. Keep the person's face unchanged."
        let spec = LucyPromptSpec(editType: .attribute, prompt: prompt, confidence: 0.9).sanitized()
        #expect(spec.prompt == prompt)
    }
}

// MARK: Template fallback tier (spec §5: the demo never depends on the LLM)

struct PromptTemplateTests {
    @Test func stormSpeechHitsCuratedThunderstorm() {
        let spec = PromptTemplates.compile("uhh put me in a thunderstorm")
        #expect(spec.editType == .background)
        #expect(spec.prompt.contains("thunderstorm"))
    }

    @Test func spookyHitsCuratedDarkForest() {
        let spec = PromptTemplates.compile("make it kinda spooky in here")
        #expect(spec.editType == .background)
        #expect(spec.prompt.contains("misty forest"))
    }

    @Test(arguments: [
        ("remove the plant behind me", LucyEditType.remove),
        ("turn me into a robot", LucyEditType.characterSwap),
        ("add a parrot on my shoulder", LucyEditType.add),
        ("take me to the moon surface", LucyEditType.background),
    ])
    func verbsClassifyIntoEditFamilies(speech: String, expected: LucyEditType) {
        #expect(PromptTemplates.compile(speech).editType == expected)
    }

    @Test func freeformFallsBackToRestyle() {
        let spec = PromptTemplates.compile("vaporwave dreamscape")
        #expect(spec.editType == .style)
        #expect(spec.prompt.contains("vaporwave dreamscape"))
    }

    @Test func templatesAlwaysProduceLucyLegalLength() {
        let speech = String(repeating: "sparkly ", count: 200)
        let spec = PromptTemplates.compile(speech).sanitized()
        #expect(spec.prompt.count <= LucyPromptSpec.maxLength)
    }
}

// MARK: Realm presets (spec §4.2)

struct RealmTests {
    @Test func sevenRealmsShipTuned() {
        #expect(Realm.all.count == 7)
    }

    @Test(arguments: Realm.all.map(\.id))
    func realmPromptsAreLucyLegal(id: String) {
        let realm = Realm.realm(withID: id)!
        #expect(realm.prompt.count <= LucyPromptSpec.maxLength)
        // Every preset carries a preserves-clause.
        #expect(realm.prompt.lowercased().contains("keep "))
        // Outcome phrasing: no negative openers.
        #expect(!realm.prompt.lowercased().hasPrefix("don't"))
    }
}

// MARK: Session model

@MainActor
struct SessionModelTests {
    @Test func castingRecordsIntoSpellbookOnce() {
        let session = SessionModel()
        let spec = Realm.all[0].promptSpec
        session.recordCast(rawSpeech: "thunderstorm", spec: spec)
        session.recordCast(rawSpeech: "thunderstorm", spec: spec)
        #expect(session.spellbook.count == 1)
        #expect(session.spellbook[0].recastCount == 1)
        #expect(session.sweepTrigger == 2)
    }

    @Test func lockedSeedSurvivesRecasts() {
        let session = SessionModel()
        session.seedLocked = true
        let seed = session.seed
        session.rerollSeedIfUnlocked()
        #expect(session.seed == seed)
        session.seedLocked = false
        session.rerollSeedIfUnlocked()
        #expect(session.seed != seed)
    }
}

// MARK: Fold layout derivation (spec §3: posture-emergent modes)

struct FoldLayoutTests {
    @Test func foldFractionComesFromDivisionMidline() {
        let layout = FoldLayout(
            mode: .director,
            divisionFrame: CGRect(x: 0, y: 390, width: 420, height: 20),
            occlusionFrames: []
        )
        #expect(layout.foldFraction(in: CGSize(width: 420, height: 800)) == 0.5)
    }

    @Test func noDivisionMeansNoSnap() {
        let layout = FoldLayout(mode: .scout, divisionFrame: nil, occlusionFrames: [])
        #expect(layout.foldFraction(in: CGSize(width: 420, height: 800)) == nil)
    }
}

// MARK: Tether wire format (spec §6.1 tier 3: USB iPhone relay)

struct TetherWireTests {
    private func acknowledgement(_ flag: UInt8, magic: String = "MTH1") -> Data {
        var data = Data(magic.utf8)
        data.append(flag)
        return data
    }

    @Test func handshakeCarriesMagicLengthAndToken() throws {
        let data = try #require(TetherWire.handshake(token: "abc123"))
        #expect(Array(data.prefix(4)) == Array("MTH1".utf8))
        #expect(data[4] == 6)
        #expect(String(decoding: data.dropFirst(5), as: UTF8.self) == "abc123")
    }

    @Test func emptyAndOversizedTokensAreRefused() {
        #expect(TetherWire.handshake(token: "") == nil)
        #expect(TetherWire.handshake(token: String(repeating: "x", count: 256)) == nil)
    }

    @Test func acknowledgementNeedsMagicAndAcceptFlag() {
        #expect(TetherWire.isAccepted(acknowledgement(1)))
        #expect(!TetherWire.isAccepted(acknowledgement(0)))
        #expect(!TetherWire.isAccepted(acknowledgement(1, magic: "NOPE")))
        #expect(!TetherWire.isAccepted(Data()))
    }

    @Test func frameLengthIsBigEndianAndBounded() {
        #expect(TetherWire.frameLength(Data([0x00, 0x01, 0x00, 0x00])) == 65_536)
        #expect(TetherWire.frameLength(Data([0, 0, 0, 0])) == nil)
        #expect(TetherWire.frameLength(Data([0xFF, 0xFF, 0xFF, 0xFF])) == nil)
        #expect(TetherWire.frameLength(Data([0, 1])) == nil)
    }

    @Test func descriptorDecodesWhatTheHelperPublishes() throws {
        let json = #"{"device":"Akshay's iPhone","pid":4242,"port":47810,"startedAt":"2026-09-25T00:00:00Z","token":"deadbeef","version":1}"#
        let descriptor = try JSONDecoder().decode(TetherDescriptor.self, from: Data(json.utf8))
        #expect(descriptor.version == 1)
        #expect(descriptor.port == 47810)
        #expect(descriptor.token == "deadbeef")
        #expect(descriptor.pid == 4242)
        #expect(descriptor.device == "Akshay's iPhone")
    }
}

// MARK: The reveal (spec §7: butterfly curtain → live feed)

@MainActor
struct StageRevealTests {
    private func makeEngine() -> (SessionModel, MorphoEngine) {
        let session = SessionModel()
        return (session, MorphoEngine(session: session, credentials: MorphoCredentials()))
    }

    @Test func firstRecordOpensTheCurtainAndArmsRecording() {
        let (session, engine) = makeEngine()
        #expect(session.stagePhase == .curtain)
        engine.toggleRecording()
        #expect(session.stagePhase == .opening)
        #expect(session.isRecording)
        // No frames yet, so no writer yet — it opens on the first real frame.
        #expect(!engine.recorder.isWriting)
    }

    @Test func openingIsOneWay() {
        let (session, engine) = makeEngine()
        engine.openStage()
        engine.openStage()
        #expect(session.stagePhase == .opening)
        session.stagePhase = .live
        engine.openStage()
        #expect(session.stagePhase == .live)
    }

    @Test func laterRecordsLeaveTheStageAlone() {
        let (session, engine) = makeEngine()
        session.stagePhase = .live
        engine.toggleRecording()
        #expect(session.stagePhase == .live)
        #expect(session.isRecording)
        engine.toggleRecording()
        #expect(!session.isRecording)
    }
}

// MARK: Feed liveness (spec §7: the butterfly returns when the phone pauses)

@MainActor
struct FeedLivenessTests {
    private func makeEngine() -> (SessionModel, MorphoEngine) {
        let session = SessionModel()
        return (session, MorphoEngine(session: session, credentials: MorphoCredentials()))
    }

    @Test func stallWhileLiveBringsTheButterflyBack() {
        let (session, engine) = makeEngine()
        session.stagePhase = .live
        session.stageArmed = true
        engine.feedDidResume()
        #expect(engine.feedIsLive)
        engine.feedDidStall()
        #expect(!engine.feedIsLive)
        #expect(session.stagePhase == .closing)
    }

    @Test func framesReturningReopenAnArmedStage() {
        let (session, engine) = makeEngine()
        session.stageArmed = true
        engine.feedDidResume()
        #expect(session.stagePhase == .opening)
    }

    @Test func framesBeforeTheFirstRecordStayBehindTheCurtain() {
        let (session, engine) = makeEngine()
        engine.feedDidResume()
        #expect(engine.feedIsLive)
        #expect(session.stagePhase == .curtain)
    }

    @Test func recordArmsTheStageAndLeavesReplay() {
        let (session, engine) = makeEngine()
        #expect(!session.stageArmed)
        engine.toggleRecording()
        #expect(session.stageArmed)
        #expect(!engine.replay.isActive)
    }
}

// MARK: The Reel (spec §9)

struct ReelTests {
    @Test func clipRoundTripsThroughJSON() throws {
        let clip = Clip(
            id: UUID(),
            fileName: "take.mp4",
            thumbnailFileName: "take.jpg",
            recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 12.4,
            width: 1280,
            height: 720,
            realmName: "Neo-Tokyo"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Clip.self, from: encoder.encode(clip))
        #expect(decoded == clip)
        #expect(decoded.durationLabel == "0:12")
        #expect(decoded.url.lastPathComponent == "take.mp4")
        #expect(decoded.thumbnailURL?.lastPathComponent == "take.jpg")
        #expect(!decoded.savedToPhotos)
    }
}
