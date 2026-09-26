//
//  RegionNamer.swift
//  Morpho
//
//  Names a segmented region with the on-device language model's image input
//  (iOS 27 Foundation Models): "Coffee Mug", "Houseplant", "Laptop". One
//  request at a time, a few per second at most, and only when the model and
//  its vision capability are actually available on this device. The
//  segmenter falls back to Vision's classifier or heuristics otherwise.
//

import CoreGraphics
import Foundation
import FoundationModels
import OSLog

@Generable
struct RegionName {
    @Guide(description: "The single main object in the image, named in one or two plain English words such as 'Coffee Mug', 'Laptop', 'Person', 'Houseplant', 'Pencil'. No articles, no sentence, no punctuation.")
    var name: String
}

final class RegionNamer {
    private static let log = Logger(subsystem: "app.morpho", category: "RegionNamer")

    private static let instructions = """
    You label objects for a camera app. You are shown a tight crop of one object \
    from a live video frame. Reply with the object's common name in one or two \
    words. Prefer the specific everyday noun (Laptop, Pencil, Router, Mug, \
    Keyboard, Person, Dog) over categories (Device, Item, Thing).
    """

    private var session: LanguageModelSession?
    private var inFlight = false
    private var consecutiveFailures = 0
    private var disabledUntil: Date?

    /// Failures in a row before the namer stands down for a while. The
    /// simulator advertises the model but can't load its assets.
    static let failuresBeforeStandingDown = 3
    static let standDownDuration: TimeInterval = 120

    /// True when the on-device model is ready and accepts images, and hasn't
    /// just failed repeatedly.
    var isAvailable: Bool {
        if let disabledUntil, disabledUntil > .now { return false }
        let model = SystemLanguageModel.default
        return model.availability == .available && model.capabilities.contains(.vision)
    }

    /// True while a request is running; callers skip rather than queue.
    var isBusy: Bool { inFlight }

    /// Names the crop, or nil when the model is unavailable, busy, slow, or
    /// answers with something that isn't a short noun phrase.
    func name(_ crop: CGImage) async -> String? {
        guard isAvailable, !inFlight else { return nil }
        inFlight = true
        defer { inFlight = false }

        do {
            let name = try await withTimeout(seconds: 4) { [self] in
                let session = self.session ?? LanguageModelSession(instructions: Self.instructions)
                self.session = session
                let prompt = Prompt {
                    "Name the main object in this image in one or two words."
                    Attachment(crop)
                }
                let response = try await session.respond(
                    to: prompt,
                    generating: RegionName.self,
                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 12)
                )
                return Self.clean(response.content.name)
            }
            consecutiveFailures = 0
            return name
        } catch {
            consecutiveFailures += 1
            // A session that has grown a long transcript or errored is cheap to replace.
            session = nil
            if consecutiveFailures == 1 {
                Self.log.notice("Naming failed: \(error.localizedDescription)")
            }
            if consecutiveFailures >= Self.failuresBeforeStandingDown {
                disabledUntil = .now.addingTimeInterval(Self.standDownDuration)
                consecutiveFailures = 0
                Self.log.notice("Language-model naming standing down for \(Int(Self.standDownDuration)) s: \(error.localizedDescription)")
            }
            return nil
        }
    }

    /// "a coffee mug." → "Coffee Mug"; anything that isn't 1–2 short words is rejected.
    static func clean(_ raw: String) -> String? {
        let stripped = raw
            .components(separatedBy: CharacterSet.letters.union(.whitespaces).union(CharacterSet(charactersIn: "-'")).inverted)
            .joined()
        var words = stripped.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let articles: Set<String> = ["a", "an", "the", "some"]
        if let first = words.first, articles.contains(first.lowercased()) { words.removeFirst() }
        guard !words.isEmpty else { return nil }
        let name = words.prefix(2).map { $0.capitalized }.joined(separator: " ")
        guard name.count <= 24 else { return nil }
        return name
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
