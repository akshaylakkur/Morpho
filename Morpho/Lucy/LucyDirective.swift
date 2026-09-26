//
//  LucyDirective.swift
//  Morpho
//
//  What Lucy should be doing to the feed right now, as one prompt. Lucy 2.5
//  holds a single prompt and applies it to every frame it receives, tracking
//  what the prompt names by its visible details. So an augmentation "holds"
//  on a moving object exactly as long as its words stay in the prompt: every
//  update re-sends the whole scene — the whole-scene cast plus every targeted
//  augmentation still in effect — never just the newest edit.
//

import Foundation

struct LucyDirective: Equatable, Sendable {
    /// One cast that contributes to the prompt.
    struct Part: Equatable, Sendable, Identifiable {
        enum Kind: Equatable, Sendable {
            case scene
            case targeted(UUID)
        }

        var kind: Kind
        var title: String
        var text: String

        var id: String {
            switch kind {
            case .scene: "scene"
            case .targeted(let id): id.uuidString
            }
        }
    }

    /// The prompt sent to Lucy (≤ `LucyPromptSpec.maxLength` characters).
    var text: String
    /// Lucy's reference image: content to introduce, resent with every prompt
    /// because `set_image` replaces atomically.
    var referenceImageData: Data?
    /// Lucy's prompt enhancement (`enhance_prompt`).
    var enrich: Bool
    /// What made it in, newest targeted cast first.
    var parts: [Part]
    /// Casts that didn't fit the length budget, oldest last.
    var droppedTitles: [String] = []

    /// Changes that matter to Lucy (the parts and titles are for people).
    func differsForLucy(from other: LucyDirective?) -> Bool {
        guard let other else { return true }
        return text != other.text || referenceImageData != other.referenceImageData || enrich != other.enrich
    }
}

/// Folds everything in effect into one Lucy-legal directive.
enum LucySceneComposer {
    static let keepClause = "Keep everything else in the scene unchanged."

    /// `augmentations` newest first, as the session stores them.
    static func directive(
        sceneCast: LucyPromptSpec?,
        augmentations: [TargetedAugmentation],
        referenceImageData: Data?,
        enrich: Bool,
        budget: Int = LucyPromptSpec.maxLength
    ) -> LucyDirective? {
        // Priority when the budget is tight: the newest targeted cast, then the
        // whole-scene cast, then older targeted casts, newest to oldest.
        var ranked: [LucyDirective.Part] = augmentations.map {
            LucyDirective.Part(kind: .targeted($0.id), title: $0.shortTitle, text: $0.spec.prompt)
        }
        if let sceneCast {
            let scene = LucyDirective.Part(kind: .scene, title: sceneCast.editType.displayName, text: sceneCast.prompt)
            ranked.insert(scene, at: min(1, ranked.count))
        }
        ranked = ranked.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !ranked.isEmpty else { return nil }

        var dropped: [String] = []
        while !ranked.isEmpty {
            if let text = compose(ranked, budget: budget) {
                return LucyDirective(
                    text: text,
                    referenceImageData: referenceImageData,
                    enrich: enrich,
                    parts: ranked,
                    droppedTitles: dropped
                )
            }
            dropped.append(ranked.removeLast().title)
        }
        return nil
    }

    /// The parts as one prompt within budget, or nil if even the compact form overflows.
    private static func compose(_ ranked: [LucyDirective.Part], budget: Int) -> String? {
        if ranked.count == 1 {
            let text = ranked[0].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count <= budget { return text }
            let compact = firstSentence(of: text)
            return compact.count <= budget ? compact : nil
        }
        // Read in the order they were cast: the scene first, then targets oldest → newest.
        let reading = ranked.filter { $0.kind == .scene } + ranked.filter { $0.kind != .scene }.reversed()
        let restylesEverything = ranked.contains { $0.kind == .scene }
        for compact in [false, true] {
            var body = reading
                .map { compact ? firstSentence(of: $0.text) : strippingKeepClauses($0.text) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            // A whole-scene restyle changes everything by design; otherwise the
            // single shared keep-clause replaces each cast's own.
            if !restylesEverything {
                body += " " + keepClause
            }
            if body.count <= budget { return body }
        }
        return nil
    }

    /// The cast's instruction without its "Keep …" sentences, which are
    /// merged into one clause for the whole prompt.
    static func strippingKeepClauses(_ text: String) -> String {
        sentences(in: text)
            .filter { !$0.lowercased().hasPrefix("keep ") }
            .joined(separator: " ")
    }

    static func firstSentence(of text: String) -> String {
        sentences(in: text).first { !$0.lowercased().hasPrefix("keep ") } ?? ""
    }

    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence {
                let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
            }
        }
        return result
    }
}
