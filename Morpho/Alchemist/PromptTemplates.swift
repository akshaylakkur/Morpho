//
//  PromptTemplates.swift
//  Morpho
//
//  The deterministic fallback tier of the Alchemist (spec §5): keyword →
//  Lucy edit templates. The demo never depends on the on-device LLM.
//

import Foundation

enum PromptTemplates {
    /// Compile casual speech into a Lucy-legal prompt without any model.
    static func compile(_ rawSpeech: String) -> LucyPromptSpec {
        let speech = rawSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = speech.lowercased()

        // Mood/scene keywords → curated full prompts (the most common demo asks).
        for (keywords, spec) in curated {
            if keywords.contains(where: lowered.contains) {
                return spec
            }
        }

        // Otherwise classify into one of the eight edit families by verb.
        let subject = cleanedSubject(from: speech)
        if lowered.contains("remove") || lowered.contains("get rid of") || lowered.contains("delete") {
            return LucyPromptSpec(
                editType: .remove,
                prompt: "Remove \(subject) from the scene, filling the space naturally with the surrounding background. Keep everything else unchanged.",
                confidence: 0.5
            )
        }
        if lowered.contains("replace") || lowered.contains("swap") || lowered.contains("turn me into") || lowered.contains("make me a") {
            return LucyPromptSpec(
                editType: .characterSwap,
                prompt: "Replace the character in the video with \(subject), matching the original pose, framing, and movement exactly. Keep the background unchanged.",
                confidence: 0.5
            )
        }
        if lowered.contains("add") || lowered.contains("give me") || lowered.contains("put a") || lowered.contains("put some") {
            return LucyPromptSpec(
                editType: .add,
                prompt: "Add \(subject) to the scene near the subject, interacting naturally with the existing lighting and motion. Keep the person and background otherwise unchanged.",
                confidence: 0.5
            )
        }
        if lowered.contains("background") || lowered.contains("behind me") || lowered.contains("put me in") || lowered.contains("take me to") {
            return LucyPromptSpec(
                editType: .background,
                prompt: "Change the background to \(subject), with lighting on the subject adjusted to match the new environment. Keep the person's face and clothing unchanged.",
                confidence: 0.5
            )
        }
        // Default: treat it as a full restyle.
        return LucyPromptSpec(
            editType: .style,
            prompt: "Transform the entire scene into \(subject), applying the look consistently to every surface. Keep the subject's pose, framing, and movement identical.",
            confidence: 0.4
        )
    }

    /// Strip leading command words so the remainder slots into a template.
    private static func cleanedSubject(from speech: String) -> String {
        var text = speech
        let prefixes = [
            "please ", "can you ", "could you ", "hey ", "um ", "uh ", "uhh ",
            "make it ", "make me ", "make the ", "turn me into ", "turn it into ",
            "add ", "remove ", "replace ", "put me in ", "take me to ", "give me ",
            "put a ", "put some ", "get rid of ", "change the background to ",
        ]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where text.lowercased().hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                changed = true
            }
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))
        return text.isEmpty ? "a dreamlike painted world" : text
    }

    /// High-frequency demo phrases mapped to pre-tuned prompts.
    private static let curated: [([String], LucyPromptSpec)] = [
        (["thunderstorm", "storm", "rain"], Realm.realm(withID: "thunderstorm")!.promptSpec),
        (["spooky", "scary", "haunted", "creepy"], LucyPromptSpec(
            editType: .background,
            prompt: "Change the background to a dark misty forest at night, pale moonlight from the left, drifting fog near the ground, and bare twisted trees in silhouette. Keep the person's face and clothing unchanged.",
            confidence: 0.7
        )),
        (["underwater", "ocean", "sea"], Realm.realm(withID: "underwater")!.promptSpec),
        (["neon", "cyberpunk", "tokyo"], Realm.realm(withID: "neo-tokyo")!.promptSpec),
        (["clay", "claymation", "stop motion"], Realm.realm(withID: "claymation")!.promptSpec),
        (["origami", "paper"], Realm.realm(withID: "origami")!.promptSpec),
        (["noir", "black and white", "detective"], Realm.realm(withID: "film-noir")!.promptSpec),
        (["golden hour", "sunset", "warm light"], Realm.realm(withID: "golden-hour")!.promptSpec),
        (["snow", "winter", "blizzard"], LucyPromptSpec(
            editType: .vfx,
            prompt: "Add heavy falling snow throughout the scene: large soft flakes drifting down, a thin layer of fresh snow accumulating on surfaces, and cold blue-white ambient light. Keep the person's face and clothing unchanged.",
            confidence: 0.7
        )),
        (["space", "astronaut", "galaxy"], LucyPromptSpec(
            editType: .background,
            prompt: "Change the background to deep space seen from a station window: dense star fields, a swirling violet nebula, and a slowly drifting blue planet below. Cool rim light on the subject. Keep the person's face and clothing unchanged.",
            confidence: 0.7
        )),
    ]
}
