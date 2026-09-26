//
//  Realm.swift
//  Morpho
//
//  Preset "Realms" — pre-tuned, Lucy-legal prompts (spec §4.2).
//  Each prompt follows the Lucy 2.5 guide: one focused edit, concrete nouns,
//  outcome phrasing, an explicit preserves-clause, ≤750 characters.
//

import SwiftUI

struct Realm: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let editType: LucyEditType
    let prompt: String
    let accent: Color
    /// Bundled looping preview (pre-event asset, spec §12). Falls back to a gradient when absent.
    let previewAssetName: String

    var promptSpec: LucyPromptSpec {
        LucyPromptSpec(editType: editType, prompt: prompt, confidence: 1.0)
    }
}

extension Realm {
    static let all: [Realm] = [
        Realm(
            id: "thunderstorm",
            name: "Thunderstorm",
            symbol: "cloud.bolt.rain.fill",
            editType: .background,
            prompt: "Change the background to a dark thunderstorm sky with towering charcoal clouds, sheets of rain falling behind the subject, and occasional white lightning flashes lighting the scene from above. Wet reflections shimmer on surfaces near the ground. Keep the person's face, hair, and clothing unchanged and clearly lit.",
            accent: Color(red: 0.45, green: 0.55, blue: 0.85),
            previewAssetName: "realm-thunderstorm"
        ),
        Realm(
            id: "claymation",
            name: "Claymation",
            symbol: "hands.and.sparkles.fill",
            editType: .style,
            prompt: "Transform the entire scene into a handcrafted claymation world: every surface becomes soft modeling clay with visible fingerprints and tool marks, rounded edges, and slightly uneven matte texture. Colors are warm and saturated like a stop-motion film set. Keep the subject's pose, framing, and movements exactly the same.",
            accent: Color(red: 0.95, green: 0.60, blue: 0.35),
            previewAssetName: "realm-claymation"
        ),
        Realm(
            id: "neo-tokyo",
            name: "Neo-Tokyo",
            symbol: "building.2.fill",
            editType: .background,
            prompt: "Change the background to a rain-slicked Neo-Tokyo street at night: dense neon signs in pink and cyan kanji, holographic billboards, steam rising from vents, and glowing paper lanterns strung overhead. Neon reflections ripple across the wet pavement. Keep the person's face, clothing, and lighting on the subject unchanged.",
            accent: Color(red: 0.98, green: 0.35, blue: 0.75),
            previewAssetName: "realm-neotokyo"
        ),
        Realm(
            id: "origami",
            name: "Origami World",
            symbol: "scribble.variable",
            editType: .style,
            prompt: "Transform the entire scene into folded paper origami: every object and surface becomes crisp folded paper with sharp creases, flat matte facets, and visible fold lines. The palette is soft pastel washi tones. Objects keep their silhouettes but read as paper sculpture. Keep the subject's pose, framing, and movement identical.",
            accent: Color(red: 0.55, green: 0.85, blue: 0.70),
            previewAssetName: "realm-origami"
        ),
        Realm(
            id: "golden-hour",
            name: "Golden Hour",
            symbol: "sun.horizon.fill",
            editType: .attribute,
            prompt: "Change the lighting of the scene to warm golden-hour sunlight: low amber sun from the left casting long soft shadows, a gentle honey-colored glow on skin and surfaces, and a hazy warm bloom in the highlights. Keep every object, the background, and the subject's appearance otherwise unchanged.",
            accent: Color(red: 1.0, green: 0.75, blue: 0.35),
            previewAssetName: "realm-goldenhour"
        ),
        Realm(
            id: "underwater",
            name: "Underwater",
            symbol: "water.waves",
            editType: .background,
            prompt: "Change the background to a sunlit underwater reef: shafts of blue-green light ray down through clear water, small silver fish drift past in loose schools, coral in muted purples and oranges grows in the distance, and tiny bubbles rise steadily. Keep the person's face, hair, and clothing unchanged and in sharp focus.",
            accent: Color(red: 0.25, green: 0.65, blue: 0.95),
            previewAssetName: "realm-underwater"
        ),
        Realm(
            id: "film-noir",
            name: "Film Noir",
            symbol: "moon.haze.fill",
            editType: .style,
            prompt: "Transform the entire scene into high-contrast black-and-white film noir: deep inky shadows, a single hard key light, venetian-blind light stripes raking across the background, and fine 35mm film grain. Keep the subject's pose, framing, and movements exactly the same.",
            accent: Color(red: 0.75, green: 0.75, blue: 0.80),
            previewAssetName: "realm-noir"
        ),
    ]

    static func realm(withID id: String) -> Realm? {
        all.first { $0.id == id }
    }
}
