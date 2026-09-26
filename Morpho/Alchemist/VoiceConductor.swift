//
//  VoiceConductor.swift
//  Morpho
//
//  Glues the voice loop together (spec §5): SpeechPipeline sentences →
//  Alchemist compilation → a brief on-screen "compiled prompt" beat →
//  MorphoEngine.cast. Owns the two mic modes: hold-to-talk and Open Mic.
//

import Foundation
import Observation

@Observable
final class VoiceConductor {
    private let pipeline = SpeechPipeline()
    private let alchemist = Alchemist()
    private let engine: MorphoEngine
    private var session: SessionModel { engine.session }

    init(engine: MorphoEngine) {
        self.engine = engine
        session.alchemistAvailable = alchemist.isAvailable

        pipeline.onVolatileTranscript = { [weak self] text in
            self?.session.liveTranscript = text
        }
        pipeline.onAmplitude = { [weak self] amplitude in
            self?.session.micAmplitude = amplitude
        }
        pipeline.onFinalSentence = { [weak self] sentence in
            self?.compileAndCast(sentence)
        }
    }

    // MARK: Mic modes

    /// Hold-to-talk press.
    func beginHold() {
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
            session.micMode = .openMic
            startListening()
        }
    }

    private func startListening() {
        Task {
            guard await pipeline.requestPermission() else {
                session.micMode = .idle
                return
            }
            do {
                try await pipeline.start()
            } catch {
                session.micMode = .idle
                session.liveTranscript = ""
            }
        }
    }

    // MARK: Speech → cast

    /// Also used by a typed incantation (keyboard fallback insurance).
    func compileAndCast(_ rawSpeech: String) {
        Task {
            let spec = await alchemist.compile(rawSpeech)
            // Flash the compiled prompt in the Incantation overlay before it
            // fires — the honest "speech morphs into the spell" beat (spec §5).
            session.compiledPreview = spec
            try? await Task.sleep(for: .milliseconds(650))
            session.compiledPreview = nil
            await engine.cast(rawSpeech: rawSpeech, spec: spec)
        }
    }
}
