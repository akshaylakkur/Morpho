//
//  Alchemist.swift
//  Morpho
//
//  The FoundationModels pass (spec §5): rewrites casual speech into Lucy-legal
//  prompts via on-device guided generation, with the deterministic template
//  engine as an always-available fallback tier.
//

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
    Edit families and their templates:
    - add: "Add [object] to [location] …"
    - replace: "Replace [original] with [new] …"
    - remove: "Remove [object] from [location] …"
    - background: "Change the background to [scene] …"
    - style: "Transform the entire scene into [style] …"
    - vfx: weather/particles/atmosphere added over the scene
    - characterSwap: "Replace the character in the video with [description] …"
    - attribute: "Change [object] to [color/material/lighting] …"
    """

    private var session: LanguageModelSession?

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
