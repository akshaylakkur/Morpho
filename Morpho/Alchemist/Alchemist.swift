//
//  Alchemist.swift
//  Morpho
//
//  The FoundationModels pass (spec §5): rewrites casual speech into Lucy-legal
//  prompts via on-device guided generation, with the deterministic template
//  engine as an always-available fallback tier.
//

import CoreGraphics
import Foundation
import FoundationModels

@Generable
struct CompiledIncantation {
    @Guide(description: "One of: add, replace, remove, background, style, vfx, characterSwap, attribute. The single Lucy edit family this request belongs to.")
    var editType: String

    @Guide(description: "The rewritten Lucy prompt: one focused edit, under 120 words, concrete nouns, outcome-phrased (never negative phrasing like 'don't' or 'no ...'), ends with a clause naming what stays unchanged.")
    var prompt: String

    @Guide(description: "Confidence from 0.0 to 1.0 that the rewrite captures the speaker's intent.")
    var confidence: Float
}

@Generable
struct TargetedIncantation {
    @Guide(description: "Two to six words naming the selected subject by what is visible: its kind plus a color, clothing, or material, e.g. 'the man in the gray hoodie', 'the white ceramic mug'. Never a screen position.")
    var subject: String

    @Guide(description: "One of: add, replace, remove, background, style, vfx, characterSwap, attribute. The single Lucy edit family this request belongs to.")
    var editType: String

    @Guide(description: "The rewritten Lucy prompt: one focused edit applied to the subject only, under 100 words, anchored by the subject's visible details, outcome-phrased (never 'don't' or 'no …'), ending with a clause that keeps everything else in the scene unchanged.")
    var prompt: String

    @Guide(description: "Confidence from 0.0 to 1.0 that the rewrite captures the speaker's intent for this subject.")
    var confidence: Float
}

final class Alchemist {
    /// Baked-in distillation of the Lucy 2.5 prompting guide.
    private static let instructions = """
    You compile casual spoken requests into prompts for Lucy 2.5, a realtime \
    video-editing model. Rules, in priority order:
    1. ONE focused edit per prompt. If the speaker asks for several things, pick the dominant one.
    2. Answer four questions in the prompt: what changes, where it is anchored \
    (by visible details, never frame position), how it interacts with the scene \
    (physical behavior, tracking, lighting), and what stays the same.
    3. Phrase outcomes, never prohibitions. Instead of "don't change the face", \
    write "Keep the person's face unchanged."
    4. Concrete nouns and material properties (gloss, weave, texture); no filler \
    adjectives like "realistic", "seamless", "natural", "magical".
    5. Never mix unrelated styles in one prompt.
    6. Keep it under 120 words.
    7. Never name copyrighted or trademarked characters, franchises, brands, \
    or real celebrities — Lucy refuses them. Describe the look instead: \
    "a ninja turtle" becomes "a ninja warrior with a green turtle shell and a \
    blue bandana mask".
    Edit families and their templates:
    - add: "Add [object] to [location] …"
    - replace: "Replace [original] with [new] …"
    - remove: "Remove [object] from [location] …"
    - background: "Change the background to [scene] …"
    - style: "Change the style of the video to [style] …"
    - vfx: "Add [effect] to [location] …" (weather, particles, atmosphere)
    - characterSwap: "Replace the character in the video with [description] …"
    - attribute: "Change [object] to [color/material/lighting] …"
    """

    private static let targetedInstructions = instructions + """

    Targeted mode: the speaker has selected ONE thing in the camera frame and is \
    describing a change to that thing only. When images are attached, the first \
    is the whole frame for context and the second is the selected thing cut out \
    of it. Anchor the edit by the thing's visible details (kind, color, clothing, \
    material) and how it sits among its surroundings, never by screen position. \
    Pronouns like "this", "it", "him" refer to the selected thing. A person asked \
    to "look like" something is a characterSwap; an object asked to "look like" \
    or "be" something else is a replace. The edit must leave everything outside \
    the selected thing unchanged, and the prompt must end by saying so.
    """

    private var session: LanguageModelSession?
    private var targetedSession: LanguageModelSession?
    /// Long side of the whole-frame attachment; enough context without a huge prompt.
    static let contextLongSide = 768

    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// Compile speech → Lucy prompt. Falls back to templates if the model is
    /// unavailable or slow (spec: the demo never depends on the LLM).
    func compile(_ rawSpeech: String) async -> LucyPromptSpec {
        guard isAvailable else {
            return PromptTemplates.compile(rawSpeech)
        }
        do {
            return try await withTimeout(seconds: 3.5) { [self] in
                let session = self.session ?? LanguageModelSession(instructions: Self.instructions)
                self.session = session
                let response = try await session.respond(
                    to: "Compile this spoken request: \"\(rawSpeech)\"",
                    generating: CompiledIncantation.self
                )
                let compiled = response.content
                let editType = LucyEditType(rawValue: compiled.editType) ?? .style
                return LucyPromptSpec(
                    editType: editType,
                    prompt: compiled.prompt,
                    confidence: max(0, min(1, compiled.confidence))
                ).sanitized()
            }
        } catch {
            return PromptTemplates.compile(rawSpeech)
        }
    }

    /// Compile speech about one locked target (click-and-augment). The whole
    /// held frame and the region cut from it are both attached when the model
    /// accepts images, so "make this look like a ninja" resolves against what
    /// the camera actually sees and where it sits; otherwise the detector's
    /// label anchors it. Falls back to the targeted templates like everything else.
    func compileTargeted(_ rawSpeech: String, target: AugmentationTarget, frame: CGImage?, crop: CGImage?) async -> LucyPromptSpec {
        guard isAvailable else {
            return PromptTemplates.compileTargeted(rawSpeech, subject: target.label)
        }
        let acceptsImages = SystemLanguageModel.default.capabilities.contains(.vision)
        let context = frame.flatMap { TargetCropper.downscaled($0, longSide: Self.contextLongSide) }
        do {
            return try await withTimeout(seconds: 6) { [self] in
                let session = self.targetedSession ?? LanguageModelSession(instructions: Self.targetedInstructions)
                self.targetedSession = session
                let label = target.label.isEmpty ? "object" : target.label
                let prompt: Prompt
                if acceptsImages, let crop, let context {
                    prompt = Prompt {
                        "The first image is the whole camera frame. The second is the thing the speaker selected, cut from it (the detector calls it \"\(label)\"). The speaker said: \"\(rawSpeech)\". Compile this into a Lucy prompt for the selected thing only."
                        Attachment(context)
                        Attachment(crop)
                    }
                } else if acceptsImages, let crop {
                    prompt = Prompt {
                        "The speaker selected the thing in the attached image (the detector calls it \"\(label)\") and said: \"\(rawSpeech)\". Compile this into a Lucy prompt for that thing only."
                        Attachment(crop)
                    }
                } else {
                    prompt = Prompt {
                        "The speaker selected a \(label) in the frame and said: \"\(rawSpeech)\". Compile this into a Lucy prompt for that thing only."
                    }
                }
                let response = try await session.respond(to: prompt, generating: TargetedIncantation.self)
                let compiled = response.content
                let editType = LucyEditType(rawValue: compiled.editType) ?? .attribute
                return LucyPromptSpec(
                    editType: editType,
                    prompt: compiled.prompt,
                    confidence: max(0, min(1, compiled.confidence))
                ).sanitized()
            }
        } catch {
            // A session that errored or timed out is cheap to replace next time.
            targetedSession = nil
            return PromptTemplates.compileTargeted(rawSpeech, subject: target.label)
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ work: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return first
        }
    }
}
