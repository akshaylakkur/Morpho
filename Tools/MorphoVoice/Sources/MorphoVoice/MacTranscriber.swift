//
//  MacTranscriber.swift
//  MorphoVoice
//
//  One listening session: the Mac's default microphone → SpeechAnalyzer with
//  the on-device SpeechTranscriber. Volatile results stream while words are
//  still settling; finals close each utterance. A session runs once — make a
//  new one for the next.
//

import AVFoundation
import Speech

final class MacTranscriber {
    enum Event {
        case ready(engine: String)
        case level(Float)
        case volatile(String)
        case final(String)
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var stopped = false

    // MARK: Shared setup

    /// The speaker's locale where the transcriber has it, else US English.
    static func locale() async -> Locale {
        if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
            return equivalent
        }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) ?? Locale(identifier: "en-US")
    }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    /// Downloads the locale's model if it isn't on this Mac yet. Run once at launch.
    static func installAssets(locale: Locale) async throws {
        let module = makeTranscriber(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            Log.info("Downloading the \(locale.identifier(.bcp47)) speech model…")
            try await request.downloadAndInstall()
        }
    }

    // MARK: Session

    func start(locale: Locale) async throws {
        let transcriber = Self.makeTranscriber(locale: locale)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw MacTranscriberError.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        try await analyzer.start(inputSequence: inputSequence)

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    self?.onEvent?(result.isFinal ? .final(text) : .volatile(text))
                }
            } catch {
                guard let self, !self.stopped else { return }
                self.onEvent?(.failed("Transcriber stopped: \(error.localizedDescription)"))
            }
        }

        try startMicrophone(analyzerFormat: analyzerFormat, continuation: continuation)
        // The client may have hung up while the model was warming.
        if stopped {
            tearDown()
            return
        }
        onEvent?(.ready(engine: "SpeechTranscriber (\(locale.identifier(.bcp47))) on \(Self.inputDeviceName)"))
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        tearDown()
    }

    private func tearDown() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        let analyzer = self.analyzer
        self.analyzer = nil
        Task {
            await analyzer?.cancelAndFinishNow()
        }
    }

    // MARK: Microphone

    private static var inputDeviceName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "the default microphone"
    }

    private func startMicrophone(
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        let input = audioEngine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            throw MacTranscriberError.noMicrophone
        }
        guard let converter = AVAudioConverter(from: micFormat, to: analyzerFormat) else {
            throw MacTranscriberError.noAudioFormat
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: micFormat) { [weak self] buffer, _ in
            self?.onEvent?(.level(Self.rmsAmplitude(of: buffer)))

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

    /// Same curve as the app's own meter so the waveform ring looks alike.
    private static func rmsAmplitude(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<frames {
            sum += channel[i] * channel[i]
        }
        return min(1, (sum / Float(frames)).squareRoot() * 14)
    }
}

enum MacTranscriberError: Error, CustomStringConvertible {
    case noAudioFormat
    case noMicrophone
    case microphoneDenied

    var description: String {
        switch self {
        case .noAudioFormat: "The Mac's transcriber reports no usable audio format"
        case .noMicrophone: "No microphone input on this Mac"
        case .microphoneDenied: "Morpho Voice isn't allowed to use the Mac's microphone (System Settings › Privacy & Security › Microphone)"
        }
    }
}
