//
//  Incantation.swift
//  Morpho
//
//  A single spoken (or preset) casting, kept in the session Spellbook (spec §4.2).
//

import Foundation

struct Incantation: Identifiable, Equatable, Sendable {
    let id: UUID
    /// What the person actually said ("uhh make it kinda spooky in here").
    let rawSpeech: String
    /// The Lucy-legal prompt the Alchemist compiled from it.
    let spec: LucyPromptSpec
    let castAt: Date
    var recastCount: Int = 0

    init(rawSpeech: String, spec: LucyPromptSpec, castAt: Date = .now) {
        self.id = UUID()
        self.rawSpeech = rawSpeech
        self.spec = spec
        self.castAt = castAt
    }
}
