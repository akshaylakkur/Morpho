//
//  SpeechPipeline.swift
//  Morpho
//
//  Live on-device transcription (spec §5): mic → SpeechAnalyzer → volatile
//  transcript for the Incantation overlay + finalized sentences for the
//  Alchemist. Also meters mic amplitude for the Incant button's waveform ring.
//
//  Tiers, tried in order: in the simulator, the Mac voice relay
//  (HostVoiceRelay — the Mac's mic and speech model, since the simulated
//  device can't run one); the on-device SpeechTranscriber where this device
//  class has it; the system dictation models (DictationTranscriber); and,
//  only where neither SpeechAnalyzer module can run at all, the legacy
//  SFSpeechRecognizer. The locale is always matched to what the module
//  actually supports rather than passed through raw.
//

import AVFoundation
import Speech

final class SpeechPipeline {
    var onVolatileTranscript: ((String) -> Void)?
    var onFinalSentence: ((String) -> Void)?
    var onAmplitude: ((Float) -> Void)?
    /// The transcriber died mid-session (with why); the pipeline has stopped itself.
    var onFailure: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var module: (any SpeechModule)?
    private var legacyRecognizer: SFSpeechRecognizer?
    private var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
    private var legacyTask: SFSpeechRecognitionTask?
    private var hostRelay: HostVoiceRelay?
    /// Which transcriber is listening, for diagnostics ("SpeechTranscriber (en-US)").
    private(set) var activeModuleDescription = ""
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?

    private var pendingVolatile = ""
    private var lastEmittedSentence = ""
    private var hasLoggedResult = false
    private(set) var isRunning = false

    // MARK: Lifecycle

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() async throws {
        guard !isRunning else { return }
        // Each session starts clean: saying the same thing to a second target must cast again.
        lastEmittedSentence = ""
        hasLoggedResult = false

        // In the simulator, the Mac does the listening when its relay is up.
        if HostVoiceRelay.isDiscoverable {
            do {
                try await startHostRelay()
                print("[SpeechPipeline] listening with \(activeModuleDescription)")
                return
            } catch {
                print("[SpeechPipeline] Mac voice relay failed to start: \(error)")
                hostRelay = nil
                // The simulator's own tiers can't transcribe; say what the relay said.
                throw error
            }
        }

        var lastError: Error = SpeechPipelineError.noTranscriber
        for candidate in await Self.candidateModules() {
            do {
                try await start(with: candidate)
                activeModuleDescription = candidate.description
                print("[SpeechPipeline] listening with \(candidate.description)")
                return
            } catch {
                lastError = error
                print("[SpeechPipeline] \(candidate.description) failed to start: \(error)")
                tearDownAnalyzer()
            }
        }
        // Neither SpeechAnalyzer module can run here (the simulator): the
        // legacy recognizer still can, on-device when it supports it.
        do {
            try await startLegacy()
            print("[SpeechPipeline] listening with \(activeModuleDescription)")
            return
        } catch {
            print("[SpeechPipeline] SFSpeechRecognizer failed to start: \(error)")
            tearDownLegacy()
            lastError = error
        }
        throw lastError
    }

    /// A transcriber plus what to call it in logs.
    private struct Candidate {
        let module: any SpeechModule
        let description: String
    }

    /// In order of preference: the on-device transcriber, then system dictation.
    private static func candidateModules() async -> [Candidate] {
        var candidates: [Candidate] = []
        let installed = await SpeechTranscriber.installedLocales.count
        let dictationInstalled = await DictationTranscriber.installedLocales.count
        print("[SpeechPipeline] SpeechTranscriber available=\(SpeechTranscriber.isAvailable) installed=\(installed) · DictationTranscriber installed=\(dictationInstalled)")
        if SpeechTranscriber.isAvailable {
            let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
            let supported = await SpeechTranscriber.supportedLocales
            if let locale = equivalent ?? preferredLocale(from: supported) {
                candidates.append(Candidate(
                module: SpeechTranscriber(
                    locale: locale,
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults],
                    attributeOptions: []
                ),
                    description: "SpeechTranscriber (\(locale.identifier(.bcp47)))"
                ))
            }
        }
        let dictationEquivalent = await DictationTranscriber.supportedLocale(equivalentTo: .current)
        let dictationSupported = await DictationTranscriber.supportedLocales
        if let locale = dictationEquivalent ?? preferredLocale(from: dictationSupported) {
            candidates.append(Candidate(
                module: DictationTranscriber(
                    locale: locale,
                    contentHints: [.shortForm],
                    transcriptionOptions: [.punctuation],
                    reportingOptions: [.volatileResults, .frequentFinalization],
                    attributeOptions: []
                ),
                description: "DictationTranscriber (\(locale.identifier(.bcp47)))"
            ))
        }
        return candidates
    }

    /// The speaker's language if the module has it in any region, else English, else anything.
    private static func preferredLocale(from supported: [Locale]) -> Locale? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return supported.first { $0.language.languageCode?.identifier == language }
            ?? supported.first { $0.language.languageCode?.identifier == "en" }
            ?? supported.first
    }

    private func start(with candidate: Candidate) async throws {
        let module = candidate.module
        self.module = module

        // Make sure the module's model assets exist before analyzing.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer

        // Freshly installed assets can take a beat to register.
        let status = await AssetInventory.status(forModules: [module])
        print("[SpeechPipeline] asset status for \(type(of: module)): \(status)")
        var format: AVAudioFormat?
        for attempt in 0..<3 {
            format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
            if format != nil { break }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(300)) }
        }
        // A module that names no format cannot take audio at all: feeding it
        // anything else traps inside the framework (AnalyzerInput.init).
        guard let analyzerFormat = format else {
            throw SpeechPipelineError.noAudioFormat
        }

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation
        try await analyzer.start(inputSequence: inputSequence)

        resultsTask = observeResults(of: module)

        try configureAudio(analyzerFormat: analyzerFormat, continuation: continuation)
        isRunning = true
    }

    /// Both transcribers vend the same shape of result; only the type differs.
    private func observeResults(of module: any SpeechModule) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                switch module {
                case let transcriber as SpeechTranscriber:
                    for try await result in transcriber.results {
                        self?.handleResult(text: String(result.text.characters), isFinal: result.isFinal)
                    }
                case let dictation as DictationTranscriber:
                    for try await result in dictation.results {
                        self?.handleResult(text: String(result.text.characters), isFinal: result.isFinal)
                    }
                default:
                    break
                }
            } catch {
                // Analyzer ended (stop() or hard failure) — nothing to do.
            }
        }
    }

    /// Tier 3: the legacy recognizer, fed raw mic buffers. Partial results
    /// are cumulative for the request, which `handleResult` accounts for.
    private func startLegacy() async throws {
        let candidates = [SFSpeechRecognizer(locale: .current), SFSpeechRecognizer(locale: Locale(identifier: "en-US")), SFSpeechRecognizer()]
        for recognizer in candidates {
            print("[SpeechPipeline] SFSpeechRecognizer \(recognizer?.locale.identifier ?? "nil") available=\(recognizer?.isAvailable ?? false) onDevice=\(recognizer?.supportsOnDeviceRecognition ?? false)")
        }
        guard let recognizer = candidates.compactMap({ $0 }).first(where: \.isAvailable) else {
            throw SpeechPipelineError.noTranscriber
        }

        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw SpeechPipelineError.speechRecognitionDenied }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        // This tier only runs where the on-device modules can't (the
        // simulator), and its on-device model is missing there too — so let
        // the recognizer pick; it stays on-device wherever it can.
        request.requiresOnDeviceRecognition = false
        legacyRecognizer = recognizer
        legacyRequest = request
        legacyTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error.map { "\($0.localizedDescription) [\(($0 as NSError).domain) \(($0 as NSError).code)]\(Self.simulatorHint)" }
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                if let text { self.handleResult(text: text, isFinal: isFinal) }
                if let failure, !isFinal {
                    print("[SpeechPipeline] SFSpeechRecognizer ended: \(failure)")
                    self.stop(flush: false)
                    self.onFailure?(failure)
                }
            }
        }

        try configureAudio(analyzerFormat: nil, continuation: nil)
        isRunning = true
        activeModuleDescription = "SFSpeechRecognizer (\(recognizer.locale.identifier(.bcp47)), on-device model: \(recognizer.supportsOnDeviceRecognition))"
    }

    /// Tier 0 (simulator): the Mac listens and transcribes; its segments
    /// arrive shaped like SpeechTranscriber's, so they take the same path.
    private func startHostRelay() async throws {
        let relay = HostVoiceRelay()
        relay.onEvent = { [weak self] event in
            guard let self, self.isRunning else { return }
            switch event {
            case .level(let amplitude):
                self.onAmplitude?(amplitude)
            case .volatile(let text):
                self.handleResult(text: text, isFinal: false)
            case .final(let text):
                self.handleResult(text: text, isFinal: true)
            case .failed(let reason):
                print("[SpeechPipeline] Mac voice relay ended: \(reason)")
                self.stop(flush: false)
                self.onFailure?(reason)
            }
        }
        hostRelay = relay
        let engine = try await relay.start()
        isRunning = true
        activeModuleDescription = "Mac voice relay · \(engine)"
    }

    private func tearDownLegacy() {
        legacyRequest?.endAudio()
        legacyTask?.cancel()
        legacyTask = nil
        legacyRequest = nil
        legacyRecognizer = nil
    }

    /// Undo a partial start so the next candidate begins from nothing.
    private func tearDownAnalyzer() {
        resultsTask?.cancel()
        resultsTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        let analyzer = self.analyzer
        self.analyzer = nil
        self.module = nil
        Task {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        }
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

        if let hostRelay {
            // The simulator's own mic never opened; hanging up closes the Mac's.
            hostRelay.stop()
            self.hostRelay = nil
        } else {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        tearDownLegacy()
        inputContinuation?.finish()
        inputContinuation = nil
        pauseTask?.cancel()
        pauseTask = nil
        resultsTask?.cancel()
        resultsTask = nil

        let analyzer = self.analyzer
        self.analyzer = nil
        self.module = nil
        activeModuleDescription = ""
        Task {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        }
    }

    // MARK: Audio plumbing

    private func configureAudio(
        analyzerFormat: AVAudioFormat?,
        continuation: AsyncStream<AnalyzerInput>.Continuation?
    ) throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let input = audioEngine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            throw SpeechPipelineError.noMicrophoneInput
        }
        let converter = analyzerFormat.flatMap { AVAudioConverter(from: micFormat, to: $0) }
        let legacyRequest = self.legacyRequest

        try input.installAudioTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] readOnlyBuffer, _ in
            // Realtime audio thread: meter + convert + hand off, nothing else.
            // The tap vends a read-only buffer; the converter needs a PCM buffer to pull from.
            let buffer = AVAudioPCMBuffer(copying: readOnlyBuffer)
            let amplitude = Self.rmsAmplitude(of: buffer)
            Task { @MainActor [weak self] in
                self?.onAmplitude?(amplitude)
            }

            guard let analyzerFormat, let continuation else {
                legacyRequest?.append(buffer)
                return
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
        if !text.isEmpty, !hasLoggedResult {
            hasLoggedResult = true
            print("[SpeechPipeline] first result from \(activeModuleDescription): \"\(text)\" final=\(isFinal)")
        }
        if isFinal {
            pauseTask?.cancel()
            emitSentence(text)
            pendingVolatile = ""
            onVolatileTranscript?("")
            return
        }

        // A cumulative partial (legacy recognizer) repeats what the pause timer
        // already emitted; only what's beyond that is still pending.
        let pending = Self.novelWords(in: text, after: lastEmittedSentence)
        pendingVolatile = pending
        onVolatileTranscript?(pending)

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
        guard sentence.count >= 3 else { return }
        let novel = Self.novelWords(in: sentence, after: lastEmittedSentence)
        guard !novel.isEmpty else { return }
        lastEmittedSentence = sentence
        onFinalSentence?(novel)
    }

    /// The recognizer's final for an utterance usually repeats what the pause
    /// timer already emitted (plus punctuation); only the words beyond that
    /// are new. A shorter repeat of the same words is nothing new at all.
    static func novelWords(in sentence: String, after previous: String) -> String {
        let new = normalizedWords(sentence)
        let old = normalizedWords(previous)
        guard !old.isEmpty, !new.isEmpty else { return sentence }
        if new == old || (new.count <= old.count && old.starts(with: new)) { return "" }
        if new.starts(with: old) {
            let words = sentence.split(separator: " ", omittingEmptySubsequences: true)
            return words.dropFirst(old.count).joined(separator: " ")
        }
        return sentence
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }
}

extension SpeechPipeline {
    /// The simulator's own speech models don't run; the Mac's do, via Tools/voice.sh.
    static var simulatorHint: String {
        #if targetEnvironment(simulator)
        " · run Tools/voice.sh on the Mac"
        #else
        ""
        #endif
    }
}

enum SpeechPipelineError: Error {
    case noAudioFormat
    /// No transcriber can run on this device.
    case noTranscriber
    /// The legacy recognizer needs the speech-recognition grant.
    case speechRecognitionDenied
    /// The input node reports no usable format (no microphone routed here).
    case noMicrophoneInput
}
