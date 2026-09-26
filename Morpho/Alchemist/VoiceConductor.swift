//
//  VoiceConductor.swift
//  Morpho
//
//  Glues the voice loop together (spec §5): SpeechPipeline sentences →
//  Alchemist compilation → a brief on-screen "compiled prompt" beat →
//  MorphoEngine.cast. Owns the three mic modes: hold-to-talk, Open Mic, and
//  targeting (click-and-augment), where everything said about one locked
//  thing in the frame accumulates until the speaker goes quiet, then becomes
//  that thing's augmentation.
//

import Foundation
import Observation
import OSLog

@Observable
final class VoiceConductor {
    private let pipeline = SpeechPipeline()
    private let alchemist = Alchemist()
    private let engine: MorphoEngine
    private var session: SessionModel { engine.session }

    /// Finalized speech for the target so far (the box shows this plus the live words).
    private var targetSpeech = ""
    private var quietTimer: Task<Void, Never>?
    private var targetingTimeout: Task<Void, Never>?
    private var stagedDismissal: Task<Void, Never>?
    /// Bumped by `stopEverything`; a cast still composing from before it is dropped.
    private var castGeneration = 0
    private static let log = Logger(subsystem: "app.morpho", category: "VoiceConductor")

    /// Quiet after the last word that ends the utterance.
    static let endOfSpeechQuiet: TimeInterval = 1.6
    /// A session that opened its mic and never heard a word gives up after this long.
    static let targetingSilenceTimeout: TimeInterval = 20
    /// How long the "microphone unavailable" message stays before the session ends.
    static let micUnavailableLinger: TimeInterval = 5
    /// How long the staged prompt stays on the card.
    static let stagedLinger: TimeInterval = 2.6

    init(engine: MorphoEngine) {
        self.engine = engine
        session.alchemistAvailable = alchemist.isAvailable

        pipeline.onVolatileTranscript = { [weak self] text in
            guard let self else { return }
            if self.session.micMode == .targeting {
                self.session.liveTranscript = Self.joined(self.targetSpeech, text)
                if !text.isEmpty { self.restartQuietTimer() }
            } else {
                self.session.liveTranscript = text
            }
        }
        pipeline.onAmplitude = { [weak self] amplitude in
            self?.session.micAmplitude = amplitude
        }
        pipeline.onFinalSentence = { [weak self] sentence in
            guard let self else { return }
            if self.session.micMode == .targeting {
                self.targetSpeech = Self.joined(self.targetSpeech, sentence)
                self.session.liveTranscript = self.targetSpeech
                // A final closes an utterance; the quiet window started at its last word.
                if self.quietTimer == nil { self.restartQuietTimer() }
            } else {
                self.compileAndCast(sentence)
            }
        }
        pipeline.onFailure = { [weak self] reason in
            guard let self else { return }
            if self.session.micMode == .targeting {
                self.session.micMode = .idle
                self.targetingMicFailed(reason)
            } else {
                self.session.micMode = .idle
                self.session.liveTranscript = ""
            }
        }
    }

    // MARK: Mic modes

    /// Hold-to-talk press.
    func beginHold() {
        cancelTargeting()
        guard session.micMode == .idle else { return }
        session.micMode = .holdToTalk
        startListening()
    }

    /// Hold-to-talk release: flush whatever was said as one incantation.
    func endHold() {
        guard session.micMode == .holdToTalk else { return }
        session.micMode = .idle
        pipeline.stop(flush: true)
    }

    /// Tap-to-latch Open Mic: continuous listening, every sentence casts.
    func toggleOpenMic() {
        if session.micMode == .openMic {
            session.micMode = .idle
            pipeline.stop(flush: false)
        } else {
            cancelTargeting()
            session.micMode = .openMic
            startListening()
        }
    }

    /// Opens the mic for the current mode. `onReady` runs once audio is
    /// flowing; on failure the mode drops back to idle and `onFailure` runs
    /// with the reason, so targeting can say so.
    private func startListening(
        onReady: @escaping @MainActor () -> Void = {},
        onFailure: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        let mode = session.micMode
        Task {
            guard await pipeline.requestPermission() else {
                Self.log.notice("Microphone permission denied")
                print("[VoiceConductor] microphone permission denied")
                if session.micMode == mode { session.micMode = .idle }
                onFailure("no microphone access")
                return
            }
            do {
                try await pipeline.start()
                // The person may have let go or cancelled while the mic was warming up.
                if session.micMode != mode {
                    pipeline.stop(flush: false)
                } else {
                    onReady()
                }
            } catch {
                Self.log.error("Speech pipeline failed to start: \(error.localizedDescription)")
                print("[VoiceConductor] speech pipeline failed to start: \(error)")
                if session.micMode == mode { session.micMode = .idle }
                session.liveTranscript = ""
                onFailure(error.localizedDescription)
            }
        }
    }

    /// Stop every voice operation: an open mic in any mode, a locked target,
    /// a prompt being composed. Nothing already heard gets cast.
    func stopEverything() {
        castGeneration += 1
        cancelTargeting()
        if session.micMode != .idle {
            pipeline.stop(flush: false)
            session.micMode = .idle
        }
        session.liveTranscript = ""
        session.compiledPreview = nil
    }

    // MARK: Speech → cast

    /// Also used by a typed incantation (keyboard fallback insurance).
    func compileAndCast(_ rawSpeech: String) {
        let generation = castGeneration
        Task {
            let spec = await alchemist.compile(rawSpeech)
            guard generation == castGeneration else { return }
            // Flash the compiled prompt in the Incantation overlay before it
            // fires — the honest "speech morphs into the spell" beat (spec §5).
            session.compiledPreview = spec
            try? await Task.sleep(for: .milliseconds(650))
            session.compiledPreview = nil
            guard generation == castGeneration else { return }
            await engine.cast(rawSpeech: rawSpeech, spec: spec)
        }
    }

    // MARK: Click-and-augment (targeted casting)

    /// A target is locked (the engine already holds its frame): the mic opens
    /// now, and everything said until the speaker goes quiet is the augmentation.
    func beginTargeting(_ target: AugmentationTarget) {
        if session.micMode != .idle { pipeline.stop(flush: false) }
        targetingTimeout?.cancel()
        stagedDismissal?.cancel()
        resetSpeech()
        session.targeting = .listening(target)
        session.targetingMicUnavailable = false
        session.targetingMicFailureReason = nil
        openTargetingMic()
    }

    /// The finger that locked the target lifted. Speech decides when the
    /// session ends, so this only updates what the card says.
    func endTargetingHold() {
        session.targetingHoldActive = false
    }

    /// Drop the target (or the half-drawn rectangle) and let the viewfinder run.
    func cancelTargeting() {
        guard session.targeting.isActive else { return }
        targetingTimeout?.cancel()
        stagedDismissal?.cancel()
        resetSpeech()
        if session.micMode == .targeting {
            pipeline.stop(flush: false)
            session.micMode = .idle
        }
        session.targeting = .idle
        session.targetingMicUnavailable = false
        session.targetingMicFailureReason = nil
        session.targetingHoldActive = false
        session.targetingMicReady = false
        session.liveTranscript = ""
        session.compiledPreview = nil
        engine.releaseTarget()
    }

    /// A finished sentence for the locked target from somewhere other than
    /// the live mic (tests, a future dictation source). Same path as speech.
    func castSpokenAugmentation(_ speech: String) {
        guard case .listening(let target) = session.targeting else { return }
        let cleaned = speech.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 3 else { return }
        compileAndAugment(cleaned, target: target)
    }

    private func openTargetingMic() {
        session.micMode = .targeting
        session.targetingMicReady = false
        startListening(onReady: { [weak self] in
            guard let self, self.session.micMode == .targeting else { return }
            self.session.targetingMicReady = true
            self.armSilenceTimeout()
        }, onFailure: { [weak self] reason in
            self?.targetingMicFailed(reason)
        })
    }

    /// The mic couldn't open, or the transcriber died: say why on the card,
    /// then end the session.
    private func targetingMicFailed(_ reason: String) {
        guard session.targeting.isListening else { return }
        Self.log.notice("Targeting cannot listen here (\(reason)); ending the session")
        session.targetingMicReady = false
        session.targetingMicUnavailable = true
        session.targetingMicFailureReason = reason
        let phase = session.targeting
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.micUnavailableLinger))
            guard let self, self.session.targeting == phase, self.session.targetingMicUnavailable else { return }
            self.cancelTargeting()
        }
    }

    /// Words are still arriving: the utterance ends only after a quiet window.
    private func restartQuietTimer() {
        quietTimer?.cancel()
        quietTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.endOfSpeechQuiet))
            guard let self, !Task.isCancelled else { return }
            self.quietTimer = nil
            self.speechDidEnd()
        }
    }

    /// The speaker went quiet: whatever was heard is the augmentation.
    private func speechDidEnd() {
        // Words still pending in the recognizer flush as a final sentence first.
        pipeline.stop(flush: true)
        session.micMode = .idle
        session.targetingMicReady = false
        let speech = targetSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .listening(let target) = session.targeting, speech.count >= 3 {
            compileAndAugment(speech, target: target)
        } else if session.targeting.isListening {
            // Nothing usable was heard; keep listening for the next attempt.
            openTargetingMic()
        }
    }

    private func compileAndAugment(_ rawSpeech: String, target: AugmentationTarget) {
        targetingTimeout?.cancel()
        quietTimer?.cancel()
        quietTimer = nil
        if session.micMode == .targeting {
            pipeline.stop(flush: false)
            session.micMode = .idle
        }
        session.targetingMicReady = false
        session.liveTranscript = ""
        session.targeting = .compiling(target, speech: rawSpeech)
        Task {
            let spec = await alchemist.compileTargeted(rawSpeech, target: target, frame: engine.heldFrame, crop: engine.heldCrop)
            guard case .compiling(let current, _) = session.targeting, current.id == target.id else { return }
            session.compiledPreview = spec
            try? await Task.sleep(for: .milliseconds(650))
            session.compiledPreview = nil
            guard case .compiling(let still, _) = session.targeting, still.id == target.id else { return }
            await engine.applyAugmentation(target: target, rawSpeech: rawSpeech, spec: spec)
            resetSpeech()
            session.targeting = .staged(target, spec)
            stagedDismissal?.cancel()
            stagedDismissal = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.stagedLinger))
                guard !Task.isCancelled, case .staged(let shown, _) = session.targeting, shown.id == target.id else { return }
                session.targeting = .idle
            }
        }
    }

    private func armSilenceTimeout() {
        targetingTimeout?.cancel()
        targetingTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.targetingSilenceTimeout))
            guard let self, !Task.isCancelled else { return }
            // Only a session that heard nothing at all gives up.
            guard self.session.targeting.isActive, self.session.micMode == .targeting,
                  self.targetSpeech.isEmpty, self.session.liveTranscript.isEmpty
            else { return }
            self.cancelTargeting()
        }
    }

    private func resetSpeech() {
        quietTimer?.cancel()
        quietTimer = nil
        targetSpeech = ""
    }

    private static func joined(_ head: String, _ tail: String) -> String {
        let tail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        return head + " " + tail
    }
}
