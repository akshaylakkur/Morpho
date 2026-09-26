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
            prompt: "Change the style of the video to \(subject), applied consistently to every surface. Keep the subject's pose, framing, and movement identical.",
            confidence: 0.4
        )
    }

    // MARK: Targeted casts (click-and-augment)

    /// Compile speech about one selected thing into a Lucy prompt anchored on
    /// it, without any model. "make this person look like a ninja" + "Person"
    /// → a character swap of the person that leaves the rest of the scene alone.
    static func compileTargeted(_ rawSpeech: String, subject: String) -> LucyPromptSpec {
        let anchor = anchorPhrase(for: subject)
        let speech = rawSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = speech.lowercased()
        let keep = " Keep everything else in the scene unchanged."
        let isPerson = anchor.contains("person") || anchor.contains("man") || anchor.contains("woman") || anchor.contains("child")

        if lowered.contains("remove") || lowered.contains("get rid of") || lowered.contains("delete") || lowered.contains("erase") {
            return LucyPromptSpec(
                editType: .remove,
                prompt: "Remove \(anchor) from the scene, filling the space with the surrounding background so nothing looks cut out." + keep,
                confidence: 0.6
            )
        }

        let swapMarkers = [" look like a ", " look like an ", " look like ", " turn into a ", " turn into an ", " turn into ", " into a ", " into an ", " into ", " become a ", " become an ", " become ", " as a ", " as an "]
        if let wanted = phrase(in: lowered, after: swapMarkers) {
            let article = wanted.hasPrefix("a ") || wanted.hasPrefix("an ") || wanted.hasPrefix("the ") ? "" : "a "
            if isPerson {
                return LucyPromptSpec(
                    editType: .characterSwap,
                    prompt: "Replace \(anchor) with \(article)\(wanted), matching the original pose, framing, and movement exactly, with lighting that matches the scene." + keep,
                    confidence: 0.6
                )
            }
            return LucyPromptSpec(
                editType: .replace,
                prompt: "Replace \(anchor) with \(article)\(wanted) in the same place and at the same scale, matching the scene's lighting and perspective." + keep,
                confidence: 0.6
            )
        }

        let addMarkers = ["add a ", "add an ", "add some ", "add ", "give it a ", "give it an ", "give it ", "give him a ", "give her a ", "give them a ", "give this ", "put a ", "put an ", "put some ", "put "]
        if let thing = phrase(in: lowered, after: addMarkers, fromStart: true) {
            let cleaned = thing
                .replacingOccurrences(of: " on it", with: "")
                .replacingOccurrences(of: " on him", with: "")
                .replacingOccurrences(of: " on her", with: "")
                .replacingOccurrences(of: " on them", with: "")
                .replacingOccurrences(of: " on this", with: "")
                .replacingOccurrences(of: " to it", with: "")
            return LucyPromptSpec(
                editType: .add,
                prompt: "Add \(cleaned) to \(anchor), attached to it and moving with it, lit to match the scene." + keep,
                confidence: 0.55
            )
        }

        // Default: an attribute change of the selected thing.
        let desire = cleanedSubject(from: resolvingPronouns(speech, anchor: anchor))
        return LucyPromptSpec(
            editType: .attribute,
            prompt: "Change \(anchor) to \(desire), keeping its shape, position, and motion the same." + keep,
            confidence: 0.45
        )
    }

    /// "Person" → "the person"; "Coffee Mug" → "the coffee mug"; unknown → "the selected object".
    static func anchorPhrase(for subject: String) -> String {
        let cleaned = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != "Selection", cleaned != "Object" else { return "the selected object" }
        return "the " + cleaned.lowercased()
    }

    /// The words after the first marker found ("look like a" → "ninja"), trimmed of trailing filler.
    private static func phrase(in text: String, after markers: [String], fromStart: Bool = false) -> String? {
        for marker in markers {
            let range: Range<String.Index>?
            if fromStart {
                range = text.hasPrefix(marker) ? text.startIndex..<text.index(text.startIndex, offsetBy: marker.count) : nil
            } else {
                range = text.range(of: marker)
            }
            guard let range else { continue }
            var tail = String(text[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))
            for suffix in [" please", " right now", " now", " for me"] where tail.hasSuffix(suffix) {
                tail = String(tail.dropLast(suffix.count))
            }
            if !tail.isEmpty { return tail }
        }
        return nil
    }

    /// "make it red" → "make the mug red", so the template never says "it".
    private static func resolvingPronouns(_ text: String, anchor: String) -> String {
        var result = " " + text.lowercased() + " "
        for pronoun in [" this person ", " that person ", " this thing ", " that thing ", " this ", " that ", " it ", " him ", " her ", " them "] {
            result = result.replacingOccurrences(of: pronoun, with: " " + anchor + " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
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
