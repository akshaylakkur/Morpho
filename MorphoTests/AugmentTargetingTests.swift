//
//  AugmentTargetingTests.swift
//  MorphoTests
//
//  Click-and-augment: geometry, the targeted template tier, the frame hold,
//  region tracking and rebinding, masks, and the typed casting path.
//

import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Morpho

// MARK: - Fixtures

private func region(id: Int, label: String, box: CGRect, outline: [CGPoint]? = nil) -> DetectedRegion {
    DetectedRegion(
        id: id,
        label: label,
        boundingBox: box,
        outline: outline ?? [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
        ],
        coverage: box.width * box.height,
        confidence: 0.9,
        kindWeight: 1,
        paletteIndex: id
    )
}

/// A solid-color frame with a contrasting patch where the "object" is.
private func solidFrame(width: Int = 480, height: Int = 854, color: UIColor = .red) -> CGImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }.cgImage!
}

/// Red/green/blue of one pixel, with (0, 0) at the top-left.
private func pixel(of image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    var data = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
        data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return (data[0], data[1], data[2])
}

private let personBox = CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.6)
private let mugBox = CGRect(x: 0.35, y: 0.55, width: 0.1, height: 0.1)

// MARK: - Geometry

struct TargetGeometryTests {
    @Test func screenAndFrameCoordinatesRoundTrip() {
        let display = TargetGeometry.displayRect(frameSize: CGSize(width: 480, height: 854), in: CGSize(width: 390, height: 500), zoom: 1)
        let point = CGPoint(x: 0.25, y: 0.75)
        let onScreen = TargetGeometry.displayPoint(point, in: display)
        let back = TargetGeometry.normalizedPoint(onScreen, in: display)
        #expect(abs(back.x - point.x) < 0.0001)
        #expect(abs(back.y - point.y) < 0.0001)
        // Scale-to-fill: the width matches the container and the height overflows it.
        #expect(abs(display.width - 390) < 0.5)
        #expect(display.height > 500)
    }

    @Test func marqueeIsClampedToTheFrame() {
        let display = CGRect(x: -50, y: 0, width: 400, height: 400)
        let normalized = TargetGeometry.normalizedRect(CGRect(x: -80, y: 100, width: 200, height: 100), in: display)
        #expect(normalized.minX == 0)
        // -80…120 on screen is -0.075…0.425 of the frame; the left edge is clamped away.
        #expect(abs(normalized.maxX - 0.425) < 0.001)
        #expect(abs(normalized.minY - 0.25) < 0.001)
    }

    @Test func hitTestPrefersTheSmallestRegionUnderThePoint() {
        let regions = [region(id: 1, label: "Person", box: personBox), region(id: 2, label: "Mug", box: mugBox)]
        #expect(TargetGeometry.region(at: CGPoint(x: 0.4, y: 0.6), in: regions)?.id == 2)
        #expect(TargetGeometry.region(at: CGPoint(x: 0.6, y: 0.3), in: regions)?.id == 1)
        #expect(TargetGeometry.region(at: CGPoint(x: 0.05, y: 0.05), in: regions) == nil)
    }

    @Test func marqueeSnapsOnlyWhenItMostlyCoversARegion() {
        let regions = [region(id: 1, label: "Person", box: personBox)]
        let close = CGRect(x: 0.28, y: 0.18, width: 0.44, height: 0.64)
        #expect(TargetGeometry.bestMatch(for: close, in: regions)?.id == 1)
        let elsewhere = CGRect(x: 0.0, y: 0.0, width: 0.2, height: 0.1)
        #expect(TargetGeometry.bestMatch(for: elsewhere, in: regions) == nil)
    }
}

// MARK: - Targeted templates (the tier that never needs the model)

struct TargetedTemplateTests {
    @Test func aPersonAskedToLookLikeSomethingIsACharacterSwap() {
        let spec = PromptTemplates.compileTargeted("make this person look like a ninja", subject: "Person")
        #expect(spec.editType == .characterSwap)
        #expect(spec.prompt.contains("the person"))
        #expect(spec.prompt.contains("ninja"))
        #expect(spec.prompt.contains("unchanged"))
        #expect(!spec.prompt.contains("this"))
        #expect(spec.prompt.count <= LucyPromptSpec.maxLength)
    }

    @Test func anObjectAskedToLookLikeSomethingIsAReplace() {
        let spec = PromptTemplates.compileTargeted("turn it into a crystal skull", subject: "Coffee Mug")
        #expect(spec.editType == .replace)
        #expect(spec.prompt.contains("the coffee mug"))
        #expect(spec.prompt.contains("crystal skull"))
    }

    @Test func removeAndAddResolveThePronounToTheSubject() {
        let removed = PromptTemplates.compileTargeted("get rid of it", subject: "Houseplant")
        #expect(removed.editType == .remove)
        #expect(removed.prompt.hasPrefix("Remove the houseplant"))

        let added = PromptTemplates.compileTargeted("add a top hat on him", subject: "Person")
        #expect(added.editType == .add)
        #expect(added.prompt.contains("top hat"))
        #expect(added.prompt.contains("the person"))
        #expect(!added.prompt.contains(" him"))
    }

    @Test func anythingElseIsAnAttributeChangeOfTheSubject() {
        let spec = PromptTemplates.compileTargeted("make it bright red", subject: "Laptop")
        #expect(spec.editType == .attribute)
        #expect(spec.prompt.contains("the laptop"))
        #expect(spec.prompt.contains("bright red"))
        #expect(!spec.prompt.contains(" it "))
    }

    @Test func unknownSubjectsAnchorGenerically() {
        #expect(PromptTemplates.anchorPhrase(for: "Selection") == "the selected object")
        #expect(PromptTemplates.anchorPhrase(for: "") == "the selected object")
        #expect(PromptTemplates.anchorPhrase(for: "Dog") == "the dog")
    }

    @Test func chipTitlesAreShortAndSpecific() {
        #expect(TargetedAugmentation.shortTitle(for: "make this person look like a ninja", editType: .characterSwap) == "Ninja")
        #expect(TargetedAugmentation.shortTitle(for: "make it bright red", editType: .attribute) == "Bright Red")
        #expect(TargetedAugmentation.shortTitle(for: "", editType: .remove) == "Remove")
    }
}

// MARK: - Session bookkeeping

struct AugmentationSessionTests {
    private func augmentation(regionID: Int?, speech: String = "make it red") -> TargetedAugmentation {
        let target = AugmentationTarget(
            source: regionID.map { .detected(regionID: $0) } ?? .manual,
            label: "Thing",
            boundingBox: mugBox,
            frameSize: CGSize(width: 480, height: 854)
        )
        return TargetedAugmentation(target: target, rawSpeech: speech, spec: PromptTemplates.compileTargeted(speech, subject: "Thing"))
    }

    @Test func respeakingOnTheSameRegionReplacesItsCast() {
        let session = SessionModel()
        session.recordAugmentation(augmentation(regionID: 4, speech: "make it red"))
        session.recordAugmentation(augmentation(regionID: 4, speech: "make it blue"))
        #expect(session.augmentations.count == 1)
        #expect(session.augmentations[0].rawSpeech == "make it blue")
        #expect(session.sweepTrigger == 2)
        #expect(session.spellbook.count == 2)
    }

    @Test func manualCastsAccumulateUpToTheCap() {
        let session = SessionModel()
        for _ in 0..<(SessionModel.maxAugmentations + 2) {
            session.recordAugmentation(augmentation(regionID: nil))
        }
        #expect(session.augmentations.count == SessionModel.maxAugmentations)
        #expect(session.hasAnyCast)
    }

    @Test func theLucyBundleCarriesTheTargetSeparatelyFromTheReference() {
        var target = AugmentationTarget(source: .manual, label: "Selection", boundingBox: mugBox, frameSize: CGSize(width: 480, height: 854))
        target.lucyImageData = Data([1, 2, 3])
        let cast = TargetedAugmentation(target: target, rawSpeech: "make it gold", spec: PromptTemplates.compileTargeted("make it gold", subject: "Selection"))
        let bundle = cast.lucyBundle(enrich: true)
        #expect(bundle.targetImageData == Data([1, 2, 3]))
        #expect(bundle.referenceImageData == nil)
        #expect(bundle.enrich)
        #expect(bundle.prompt == cast.spec.prompt)
    }
}

// MARK: - The frame hold and tracking

@MainActor
struct TargetingEngineTests {
    private func makeEngine() -> (SessionModel, MorphoEngine) {
        let session = SessionModel()
        return (session, MorphoEngine(session: session, credentials: MorphoCredentials()))
    }

    @Test func lockingARegionHoldsTheFrameAndCropsTheTarget() throws {
        let (_, engine) = makeEngine()
        engine.ingest(solidFrame())
        let target = try #require(engine.lockTarget(region: region(id: 3, label: "Person", box: personBox)))
        #expect(engine.heldFrame != nil)
        #expect(engine.heldCrop != nil)
        #expect(target.label == "Person")
        #expect(target.regionID == 3)
        #expect(target.cropData != nil)
        #expect(target.lucyImageData != nil)
        #expect(target.frameSize == CGSize(width: 480, height: 854))

        // Lucy wants a padded 9:16 image at least 512 px on the short side.
        let lucyImageData = try #require(target.lucyImageData)
        let padded = try #require(UIImage(data: lucyImageData))
        #expect(padded.size.width >= 512)
        #expect(abs(padded.size.width / padded.size.height - 9.0 / 16.0) < 0.01)
    }

    @Test func nothingLocksWithoutAFrame() {
        let (_, engine) = makeEngine()
        #expect(engine.lockTarget(region: region(id: 1, label: "Person", box: personBox)) == nil)
        #expect(engine.heldFrame == nil)
    }

    @Test func aMarqueeSnapsToTheRegionItCoversOrStaysManual() throws {
        let (_, engine) = makeEngine()
        engine.ingest(solidFrame())
        let regions = [region(id: 9, label: "Laptop", box: personBox)]
        let snapped = try #require(engine.lockTarget(manualRect: personBox.insetBy(dx: 0.02, dy: 0.02), snappingTo: regions))
        #expect(snapped.regionID == 9)
        #expect(snapped.label == "Laptop")
        let free = try #require(engine.lockTarget(manualRect: CGRect(x: 0.02, y: 0.02, width: 0.15, height: 0.1), snappingTo: regions))
        #expect(free.source == .manual)
        #expect(free.label == "Selection")
    }

    @Test func applyingReleasesTheHoldAndFilesTheCast() async throws {
        let (session, engine) = makeEngine()
        engine.ingest(solidFrame())
        let target = try #require(engine.lockTarget(region: region(id: 3, label: "Person", box: personBox)))
        let spec = PromptTemplates.compileTargeted("make this person look like a ninja", subject: "Person")
        await engine.applyAugmentation(target: target, rawSpeech: "make this person look like a ninja", spec: spec)
        #expect(engine.heldFrame == nil)
        #expect(engine.heldCrop == nil)
        #expect(session.augmentations.count == 1)
        #expect(session.spellbook.count == 1)
        #expect(session.sweepTrigger == 1)
        #expect(engine.augmentationsByRegion()[3]?.shortTitle == "Ninja")
        #expect(session.connection == .connected)
    }

    @Test func aStagedCastLeavesTheFeedUntouchedUntilLucyIsConnected() async throws {
        let (_, engine) = makeEngine()
        let frame = solidFrame(color: .red)
        engine.ingest(frame)
        let target = try #require(engine.lockTarget(region: region(id: 3, label: "Person", box: personBox)))
        await engine.applyAugmentation(target: target, rawSpeech: "make this person look like a ninja", spec: PromptTemplates.compileTargeted("make this person look like a ninja", subject: "Person"))

        engine.ingest(frame)
        let transformed = try #require(engine.transformedFrame)
        for (x, y) in [(240, 427), (20, 20)] {
            let after = pixel(of: transformed, x: x, y: y)
            let before = pixel(of: frame, x: x, y: y)
            #expect(after.r == before.r && after.g == before.g && after.b == before.b)
        }
    }

    @Test func aStagedCastFollowsItsRegionAcrossPasses() async throws {
        let (_, engine) = makeEngine()
        engine.ingest(solidFrame())
        let target = try #require(engine.lockTarget(region: region(id: 3, label: "Person", box: personBox)))
        await engine.applyAugmentation(target: target, rawSpeech: "make it gold", spec: PromptTemplates.compileTargeted("make it gold", subject: "Person"))
        #expect(engine.augmentationsByRegion()[3] != nil)
    }

    @Test func clearingTheRealmDropsTargetedCastsToo() async throws {
        let (session, engine) = makeEngine()
        engine.ingest(solidFrame())
        let target = try #require(engine.lockTarget(region: region(id: 3, label: "Person", box: personBox)))
        await engine.applyAugmentation(target: target, rawSpeech: "make it gold", spec: PromptTemplates.compileTargeted("make it gold", subject: "Person"))
        #expect(session.hasAnyCast)
        engine.clearRealm()
        #expect(session.augmentations.isEmpty)
        #expect(!session.hasAnyCast)
    }

    @Test func aStalledFeedReleasesTheHold() throws {
        let (session, engine) = makeEngine()
        session.stagePhase = .live
        engine.ingest(solidFrame())
        _ = try #require(engine.lockTarget(region: region(id: 3, label: "Person", box: personBox)))
        #expect(engine.heldFrame != nil)
        engine.feedDidStall()
        #expect(session.stagePhase == .closing)
        // Frames are cleared once the wings are home; the hold goes with them.
        engine.releaseTarget()
        #expect(engine.heldFrame == nil)
    }
}

// MARK: - A finished sentence through the conductor

@MainActor
struct SpokenAugmentationTests {
    @Test func aFinishedSentenceCastsOntoTheLockedTarget() async throws {
        let session = SessionModel()
        let engine = MorphoEngine(session: session, credentials: MorphoCredentials())
        let conductor = VoiceConductor(engine: engine)
        engine.ingest(solidFrame())
        let target = try #require(engine.lockTarget(region: region(id: 5, label: "Person", box: personBox)))
        session.targeting = .listening(target)

        conductor.castSpokenAugmentation("make this person look like a ninja")
        guard case .compiling = session.targeting else {
            Issue.record("a sentence should move the session into compiling")
            return
        }

        // The card shows the staged prompt once the engine's generating beat ends.
        for _ in 0..<50 {
            if case .staged = session.targeting { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(session.augmentations.count == 1)
        #expect(session.augmentations[0].spec.editType == .characterSwap)
        guard case .staged(let staged, let spec) = session.targeting else {
            Issue.record("the card should show the staged prompt before going away")
            return
        }
        #expect(staged.id == target.id)
        #expect(spec == session.augmentations[0].spec)
        #expect(engine.heldFrame == nil)
    }

    @Test func tooShortInputIsIgnored() throws {
        let session = SessionModel()
        let engine = MorphoEngine(session: session, credentials: MorphoCredentials())
        let conductor = VoiceConductor(engine: engine)
        engine.ingest(solidFrame())
        let target = try #require(engine.lockTarget(region: region(id: 5, label: "Person", box: personBox)))
        session.targeting = .listening(target)
        conductor.castSpokenAugmentation("  a ")
        #expect(session.targeting == .listening(target))
    }

    @Test func cancellingReleasesEverything() throws {
        let session = SessionModel()
        let engine = MorphoEngine(session: session, credentials: MorphoCredentials())
        let conductor = VoiceConductor(engine: engine)
        engine.ingest(solidFrame())
        let target = try #require(engine.lockTarget(region: region(id: 5, label: "Person", box: personBox)))
        session.targeting = .listening(target)
        session.micMode = .targeting
        conductor.cancelTargeting()
        #expect(session.targeting == .idle)
        #expect(session.micMode == .idle)
        #expect(engine.heldFrame == nil)
    }
}

// MARK: - Repeated finals

struct NovelWordsTests {
    @Test func aFinalThatRepeatsThePauseEmissionAddsNothing() {
        #expect(SpeechPipeline.novelWords(in: "Make this person look like a ninja.", after: "make this person look like a ninja") == "")
    }

    @Test func aFinalThatExtendsItAddsOnlyTheTail() {
        #expect(SpeechPipeline.novelWords(in: "make this person look like a ninja", after: "make this person") == "look like a ninja")
    }

    @Test func unrelatedSentencesPassThrough() {
        #expect(SpeechPipeline.novelWords(in: "and give him a sword", after: "make this person look like a ninja") == "and give him a sword")
        #expect(SpeechPipeline.novelWords(in: "anything", after: "") == "anything")
    }
}
