//
//  LucyPrompt.swift
//  Morpho
//
//  Shared vocabulary for prompts flowing from voice → Alchemist → Decart.
//

import Foundation

/// The eight Lucy 2.5 edit families from the prompting guide.
enum LucyEditType: String, Codable, CaseIterable, Sendable {
    case add
    case replace
    case remove
    case background
    case style
    case vfx
    case characterSwap
    case attribute

    var displayName: String {
        switch self {
        case .add: "Add"
        case .replace: "Replace"
        case .remove: "Remove"
        case .background: "Background"
        case .style: "Restyle"
        case .vfx: "VFX"
        case .characterSwap: "Character"
        case .attribute: "Attribute"
        }
    }
}

/// A compiled, Lucy-legal prompt ready to cast.
struct LucyPromptSpec: Equatable, Sendable {
    /// Lucy prompts cap out around 750 characters of English (~120 words).
    static let maxLength = 750

    var editType: LucyEditType
    var prompt: String
    var confidence: Float

    /// Guardrail pass (spec §5): length clamp, no negative phrasing, one focused edit.
    func sanitized() -> LucyPromptSpec {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > Self.maxLength {
            text = String(text.prefix(Self.maxLength))
            // Cut on the last sentence boundary so we never send a dangling clause.
            if let lastPeriod = text.lastIndex(of: ".") {
                text = String(text[...lastPeriod])
            }
        }
        // Lucy responds to outcomes, not prohibitions.
        text = Self.outcomePhrased(text)
        return LucyPromptSpec(editType: editType, prompt: text, confidence: confidence)
    }

    /// Rewrites prohibitions as outcomes: "Don't change the face." → "Keep
    /// the face unchanged." Any other negative sentence ("No hats.") is
    /// dropped, since naming the thing tends to summon it.
    static func outcomePhrased(_ text: String) -> String {
        let keepPattern = #"^(?:please\s+)?(?:don't|do not|never|avoid)\s+(?:changing|change|altering|alter|modifying|modify|touching|touch|editing|edit|affecting|affect)\s+(.+?)[.!]?$"#
        let negativeOpeners = ["don't ", "do not ", "never ", "avoid ", "no ", "without ", "please don't ", "please do not "]
        var kept: [String] = []
        var sentences: [String] = []
        // Dictation writes a typographic apostrophe ("don’t").
        for sentence in LucySceneComposer.sentences(in: text.replacingOccurrences(of: "\u{2019}", with: "'")) {
            // "Don't change the face but make the jacket red": the wish comes
            // first, then the prohibition on its own.
            let lowered = sentence.lowercased()
            if negativeOpeners.contains(where: lowered.hasPrefix),
               let but = sentence.range(of: " but ", options: .caseInsensitive) {
                var wish = String(sentence[but.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !wish.hasSuffix(".") && !wish.hasSuffix("!") { wish += "." }
                sentences.append(wish.prefix(1).uppercased() + wish.dropFirst())
                sentences.append(String(sentence[..<but.lowerBound]) + ".")
            } else {
                sentences.append(sentence)
            }
        }
        for sentence in sentences {
            let lowered = sentence.lowercased()
            if sentence.range(of: keepPattern, options: [.regularExpression, .caseInsensitive]) != nil {
                let object = sentence.replacingOccurrences(of: keepPattern, with: "$1", options: [.regularExpression, .caseInsensitive])
                kept.append("Keep \(object) unchanged.")
            } else if negativeOpeners.contains(where: lowered.hasPrefix) {
                continue
            } else {
                kept.append(sentence)
            }
        }
        let result = kept.joined(separator: " ")
        return result.isEmpty ? text : result
    }
}
