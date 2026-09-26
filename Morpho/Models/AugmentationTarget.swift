//
//  AugmentationTarget.swift
//  Morpho
//
//  Adaptive click-and-augment: a region of the viewfinder the person locked
//  (a detected object, or a rectangle they drew) and the augmentation they
//  spoke onto it. The target's frame is *held* the moment it is locked so the
//  selection cannot drift while they speak; after the cast, the augmentation
//  follows the tracked region on the live feed.
//

import CoreGraphics
import Foundation

/// Where a target came from.
enum TargetSource: Equatable, Sendable {
    /// Bound to a region tracked by the scene segmenter.
    case detected(regionID: Int)
    /// Drawn by hand over the viewfinder.
    case manual
}

struct AugmentationTarget: Identifiable, Equatable, Sendable {
    let id: UUID
    var source: TargetSource
    /// What the detector called it ("Person", "Coffee Mug"), or "Selection".
    var label: String
    /// Normalized to the frame, origin at the upper-left.
    var boundingBox: CGRect
    /// Traced boundary in normalized upper-left points; empty means the box is the shape.
    var outline: [CGPoint]
    /// Pixel size of the frame the target was taken from.
    var frameSize: CGSize
    /// A tight crop of the target, JPEG. Grounds the on-device compile.
    var cropData: Data?
    /// The same crop padded to Lucy's aspect (16:9 or 9:16, ≥ 512 px), JPEG.
    var lucyImageData: Data?
    let heldAt: Date

    init(
        id: UUID = UUID(),
        source: TargetSource,
        label: String,
        boundingBox: CGRect,
        outline: [CGPoint] = [],
        frameSize: CGSize,
        cropData: Data? = nil,
        lucyImageData: Data? = nil,
        heldAt: Date = .now
    ) {
        self.id = id
        self.source = source
        self.label = label
        self.boundingBox = boundingBox
        self.outline = outline
        self.frameSize = frameSize
        self.cropData = cropData
        self.lucyImageData = lucyImageData
        self.heldAt = heldAt
    }

    var isDetected: Bool {
        if case .detected = source { return true }
        return false
    }

    var regionID: Int? {
        if case .detected(let id) = source { return id }
        return nil
    }

    /// "the person", "the coffee mug", "the selected object".
    var anchorPhrase: String {
        let cleaned = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != "Selection", cleaned != "Object" else { return "the selected object" }
        return "the " + cleaned.lowercased()
    }
}

/// A cast that applies to one target only.
struct TargetedAugmentation: Identifiable, Equatable, Sendable {
    let id: UUID
    var target: AugmentationTarget
    /// What the person said ("make this person look like a ninja").
    let rawSpeech: String
    /// The Lucy-legal prompt compiled for the target.
    var spec: LucyPromptSpec
    let castAt: Date

    init(id: UUID = UUID(), target: AugmentationTarget, rawSpeech: String, spec: LucyPromptSpec, castAt: Date = .now) {
        self.id = id
        self.target = target
        self.rawSpeech = rawSpeech
        self.spec = spec
        self.castAt = castAt
    }

    /// One to three words for the region chip: "Ninja", "Bright Red".
    var shortTitle: String {
        Self.shortTitle(for: rawSpeech, editType: spec.editType)
    }

    /// What the Lucy hookup receives for this cast.
    func lucyBundle(enrich: Bool) -> LucyCastBundle {
        LucyCastBundle(
            prompt: spec.prompt,
            editType: spec.editType,
            targetImageData: target.lucyImageData,
            referenceImageData: nil,
            enrich: enrich
        )
    }

    static func shortTitle(for speech: String, editType: LucyEditType) -> String {
        let lowered = speech.lowercased()
            .replacingOccurrences(of: "[^a-z0-9' ]", with: " ", options: .regularExpression)
        let markers = [" look like a ", " look like an ", " look like ", " into a ", " into an ", " into ", " as a ", " as an ", " become a ", " become ", " with a ", " with an ", " with ", " like a ", " like an ", " like ", " to a ", " to an "]
        var tail: String?
        for marker in markers {
            if let range = lowered.range(of: marker, options: .backwards) {
                tail = String(lowered[range.upperBound...])
                break
            }
        }
        let words = (tail ?? Self.strippedCommand(lowered))
            .split(separator: " ")
            .map(String.init)
            .filter { !Self.fillerWords.contains($0) }
            .prefix(3)
        guard !words.isEmpty else { return editType.displayName }
        return words.map(\.capitalized).joined(separator: " ")
    }

    private static let fillerWords: Set<String> = [
        "make", "this", "that", "it", "him", "her", "them", "the", "a", "an", "please", "kinda", "sort", "of",
        "really", "very", "um", "uh", "uhh", "look", "turn", "into", "be", "become", "person", "object", "thing",
    ]

    private static func strippedCommand(_ text: String) -> String {
        var result = text
        for prefix in ["please ", "can you ", "could you ", "make ", "turn ", "give ", "put ", "change ", "add ", "remove "]
            where result.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
        }
        return result
    }
}

/// The input the Lucy 2.5 session receives for one cast. Lucy's own reference
/// image slot is for content to *introduce* ("… from the reference image"),
/// which is why the target crop rides separately: it grounds the prompt, and
/// the hookup decides whether to also send it as the reference.
struct LucyCastBundle: Equatable, Sendable {
    var prompt: String
    var editType: LucyEditType
    var targetImageData: Data?
    var referenceImageData: Data?
    var enrich: Bool
}

/// Where the click-and-augment flow is (spec: adaptive click and augment).
enum TargetingPhase: Equatable, Sendable {
    case idle
    /// A target is locked, the viewfinder holds its frame, and the mic is open.
    case listening(AugmentationTarget)
    /// Speech finalized; the on-device model is composing the prompt against the crop.
    case compiling(AugmentationTarget, speech: String)
    /// The prompt is bundled for Lucy; shown briefly before the card goes away.
    case staged(AugmentationTarget, LucyPromptSpec)

    var target: AugmentationTarget? {
        switch self {
        case .idle: nil
        case .listening(let target): target
        case .compiling(let target, _): target
        case .staged(let target, _): target
        }
    }

    var isActive: Bool { self != .idle }

    var isListening: Bool {
        if case .listening = self { return true }
        return false
    }

    /// The viewfinder is frozen on the target's frame in these phases.
    var holdsFrame: Bool {
        switch self {
        case .listening, .compiling: true
        case .idle, .staged: false
        }
    }
}
