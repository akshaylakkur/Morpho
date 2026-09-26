//
//  ControllerTests.swift
//  MorphoTests
//
//  The Deck's new paths: words for unnamed selections, exact manual crops,
//  and background templates that leave targeted casts alone.
//

import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Morpho

@MainActor
struct TargetDescriberTests {
    @Test func placementReadsLikeAPerson() {
        #expect(TargetDescriber.placement(of: CGRect(x: 0.05, y: 0.7, width: 0.2, height: 0.2)) == "in the lower left of the frame")
        #expect(TargetDescriber.placement(of: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)) == "in the center of the frame")
        #expect(TargetDescriber.placement(of: CGRect(x: 0.75, y: 0.4, width: 0.2, height: 0.2)) == "on the right side of the frame")
    }

    @Test func colorsGetPlainNames() {
        #expect(TargetDescriber.colorName(UIColor(white: 0.25, alpha: 1)) == "dark gray")
        #expect(TargetDescriber.colorName(UIColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)) == "red")
        #expect(TargetDescriber.colorName(UIColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)) == "blue")
        #expect(TargetDescriber.colorName(.black) == "black")
    }

    @Test func anUnnamedSelectionIsAnchoredByItsLook() {
        let target = AugmentationTarget(
            source: .manual,
            label: "Selection",
            boundingBox: CGRect(x: 0.05, y: 0.7, width: 0.2, height: 0.2),
            frameSize: CGSize(width: 720, height: 1280),
            descriptor: "dark gray object in the lower left of the frame"
        )
        #expect(target.anchorPhrase == "the dark gray object in the lower left of the frame")
        let spec = PromptTemplates.compileTargeted("make this bright red", subject: target.promptSubject)
        #expect(spec.prompt.contains("the dark gray object in the lower left of the frame"))
        #expect(!spec.prompt.contains("selected object"))
    }
}

@MainActor
struct ControllerEngineTests {
    private func makeEngine() -> (SessionModel, MorphoEngine) {
        let session = SessionModel()
        return (session, MorphoEngine(session: session, credentials: MorphoCredentials()))
    }

    private func frame() -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 360, height: 640), format: format).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 360, height: 640))
        }.cgImage!
    }

    @Test func aDrawnBoxLocksExactlyAndIsDescribed() throws {
        let (_, engine) = makeEngine()
        engine.ingest(frame())
        let box = CGRect(x: 0.05, y: 0.7, width: 0.2, height: 0.2)
        let target = try #require(engine.lockTarget(manualRect: box))
        #expect(target.boundingBox == box)
        #expect(target.source == .manual)
        #expect(target.descriptor == "dark gray object in the lower left of the frame")
    }

    @Test func backdropsToggleWithoutTouchingTargetedCasts() async throws {
        let (session, engine) = makeEngine()
        engine.ingest(frame())
        let target = try #require(engine.lockTarget(manualRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)))
        await engine.applyAugmentation(target: target, rawSpeech: "make this red", spec: PromptTemplates.compileTargeted("make this red", subject: target.promptSubject))

        let beach = try #require(Realm.backdrops.first { $0.id == "tropical-beach" })
        await engine.castRealm(beach)
        #expect(session.activeRealm == beach)
        #expect(session.augmentations.count == 1)

        engine.toggleBackdrop(beach)
        #expect(session.activeRealm == nil)
        #expect(session.lastCast == nil)
        #expect(session.augmentations.count == 1)
    }

    @Test func thereAreFiveLucyLegalBackgrounds() {
        #expect(Realm.backdrops.count == 5)
        for backdrop in Realm.backdrops {
            #expect(backdrop.editType == .background)
            #expect(backdrop.prompt.hasPrefix("Change the background to"))
            #expect(backdrop.prompt.count <= LucyPromptSpec.maxLength)
        }
    }

    @Test func backToOriginalClearsEverything() async throws {
        let (session, engine) = makeEngine()
        engine.ingest(frame())
        let target = try #require(engine.lockTarget(manualRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)))
        await engine.applyAugmentation(target: target, rawSpeech: "make this red", spec: PromptTemplates.compileTargeted("make this red", subject: target.promptSubject))
        await engine.castRealm(Realm.backdrops[0])
        #expect(session.hasAnyCast)

        engine.revertToOriginal()
        #expect(!session.hasAnyCast)
        #expect(session.augmentations.isEmpty)
        #expect(session.activeRealm == nil)
        #expect(session.lucy.directive == nil)
        engine.ingest(frame())
        #expect(engine.transformedFrame === engine.originalFrame)
    }
}
