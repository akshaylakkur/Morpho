//
//  SpeechPipeline.swift
//  Morpho
//
//  Live on-device transcription (spec §5): mic → SpeechAnalyzer/SpeechTranscriber
//  → volatile transcript for the Incantation overlay + finalized sentences for
//  the Alchemist. Also meters mic amplitude for the Incant button's waveform ring.
//

import AVFoundation
import Speech

final class SpeechPipeline {
    var onVolatileTranscript: ((String) -> Void)?
    var onFinalSentence: ((String) -> Void)?
    var onAmplitude: ((Float) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?

    private var pendingVolatile = ""
    private var lastEmittedSentence = ""
    private(set) var isRunning = false

    // MARK: Lifecycle

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() async throws {
        guard !isRunning else { return }

        let transcriber = SpeechTranscriber(
            locale: Locale.current,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        // Make sure the on-device model assets exist before analyzing.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechPipelineError.noAudioFormat
        }

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation
        try await analyzer.start(inputSequence: inputSequence)

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    self?.handleResult(text: text, isFinal: result.isFinal)
                }
            } catch {
                // Analyzer ended (stop() or hard failure) — nothing to do.
            }
        }

        try configureAudio(analyzerFormat: analyzerFormat, continuation: continuation)
        isRunning = true
    }

    /// Stop listening. Emits any pending volatile text as a final sentence
    /// first when `flush` is set (hold-to-talk release).
    func stop(flush: Bool) {
        guard isRunning else { return }
        isRunning = false

        if flush {
            emitSentence(pendingVolatile)
        }
        pendingVolatile = ""
        onVolatileTranscript?("")
        onAmplitude?(0)

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        pauseTask?.cancel()
        pauseTask = nil
        resultsTask?.cancel()
        resultsTask = nil

        let analyzer = self.analyzer
        self.analyzer = nil
        self.transcriber = nil
        Task {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        }
    }

    // MARK: Audio plumbing

    private func configureAudio(
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let input = audioEngine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: micFormat, to: analyzerFormat)

        try input.installAudioTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] readOnlyBuffer, _ in
            // Realtime audio thread: meter + convert + hand off, nothing else.
            // The tap vends a read-only buffer; the converter needs a PCM buffer to pull from.
            let buffer = AVAudioPCMBuffer(copying: readOnlyBuffer)
            let amplitude = Self.rmsAmplitude(of: buffer)
            Task { @MainActor [weak self] in
                self?.onAmplitude?(amplitude)
            }

            guard let converter else { return }
            let ratio = analyzerFormat.sampleRate / micFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, converted.frameLength > 0 else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private nonisolated static func rmsAmplitude(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frames {
            sum += channel[i] * channel[i]
        }
        let rms = (sum / Float(frames)).squareRoot()
        // Perceptual-ish curve so quiet speech still moves the ring.
        return min(1, rms * 14)
    }

    // MARK: Sentence segmentation (pause detection)

    private func handleResult(text: String, isFinal: Bool) {
        if isFinal {
            pauseTask?.cancel()
            emitSentence(text)
            pendingVolatile = ""
            onVolatileTranscript?("")
            return
        }

        pendingVolatile = text
        onVolatileTranscript?(text)

        // If the speaker goes quiet for a beat, treat the utterance as a sentence.
        pauseTask?.cancel()
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, !Task.isCancelled else { return }
            let pending = self.pendingVolatile
            self.pendingVolatile = ""
            self.onVolatileTranscript?("")
            self.emitSentence(pending)
        }
    }

    private func emitSentence(_ text: String) {
        let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sentence.count >= 3, sentence != lastEmittedSentence else { return }
        lastEmittedSentence = sentence
        onFinalSentence?(sentence)
    }
}

enum SpeechPipelineError: Error {
    case noAudioFormat
}
