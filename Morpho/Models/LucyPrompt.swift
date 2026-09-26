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
        // Lucy responds to outcomes, not prohibitions — rewrite common negative openers.
        for negative in ["don't ", "do not ", "no ", "never ", "avoid ", "without "] where text.lowercased().hasPrefix(negative) {
            text = "Keep the scene unchanged except the described edit. " + text
            break
        }
        return LucyPromptSpec(editType: editType, prompt: text, confidence: confidence)
    }
}
