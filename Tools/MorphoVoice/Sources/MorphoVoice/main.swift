//
//  main.swift
//  MorphoVoice
//
//  The iPhone simulator can open the Mac's microphone but can't run any
//  speech model on it (SpeechTranscriber is unavailable, DictationTranscriber
//  vends no audio format, and SFSpeechRecognizer fails with kLSRErrorDomain
//  300). The Mac can: this helper listens on the Mac's own microphone,
//  transcribes on-device, and streams the words to Morpho over loopback.
//
//  Modes:
//    (default)         relay for the simulator; the mic opens only while
//                      Morpho is listening for a target
//    --listen          print live transcription to the terminal (no simulator)
//    --selftest "…"    speak a phrase with `say`, transcribe it, compare
//
//  Transcripts leave this process only over loopback (127.0.0.1) to clients
//  that present the per-launch token published in
//  ~/Library/Application Support/Morpho/voice.json (mode 0600).
//

import AVFoundation
import Foundation
import Security
import Speech

var port: UInt16 = 47811
var mode = "relay"
var selftestPhrase = "Make this look like a ninja wearing a red scarf"
/// Kept alive for the life of the process.
var signalSources: [DispatchSourceSignal] = []
var listenSession: MacTranscriber?
var arguments = Array(CommandLine.arguments.dropFirst()).makeIterator()
while let flag = arguments.next() {
    switch flag {
    case "--listen":
        mode = "listen"
    case "--selftest":
        mode = "selftest"
        if let phrase = arguments.next() { selftestPhrase = phrase }
    case "--port":
        guard let raw = arguments.next(), let value = UInt16(raw) else {
            Log.error("--port needs a number")
            exit(64)
        }
        port = value
    case "--help", "-h":
        print("usage: MorphoVoice [--listen | --selftest \"phrase\"] [--port n (default 47811)]")
        exit(0)
    default:
        Log.error("unknown option \(flag)")
        exit(64)
    }
}

/// Blocks nothing: resolves once the person answers the macOS prompt.
func microphoneAllowed() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined:
        Log.info("Requesting microphone access — approve the macOS prompt to continue…")
        return await AVCaptureDevice.requestAccess(for: .audio)
    default: return false
    }
}

func runSelfTest(phrase: String, locale: Locale) async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "morpho-voice-selftest.aiff")
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", url.path, phrase]
    try say.run()
    say.waitUntilExit()

    let transcriber = MacTranscriber.makeTranscriber(locale: locale)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    async let heard: String = transcriber.results.reduce("") { text, result in
        result.isFinal ? text + String(result.text.characters) : text
    }
    let file = try AVAudioFile(forReading: url)
    if let last = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: last)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    let transcript = try await heard.trimmingCharacters(in: .whitespaces)
    try? FileManager.default.removeItem(at: url)

    func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    // Longest common subsequence: a dropped or extra word costs one, not the rest of the line.
    let expected = words(phrase)
    let actual = words(transcript)
    var row = [Int](repeating: 0, count: actual.count + 1)
    for word in expected {
        var diagonal = 0
        for j in actual.indices {
            let above = row[j + 1]
            row[j + 1] = word == actual[j] ? diagonal + 1 : max(row[j + 1], row[j])
            diagonal = above
        }
    }
    let matched = row[actual.count]
    print("Spoke: \(phrase)")
    print("Heard: \(transcript)")
    print("Word match: \(matched)/\(expected.count)")
    exit(matched * 10 >= expected.count * 8 ? 0 : 1)
}

func runListen(locale: Locale) async throws {
    let transcriber = MacTranscriber()
    listenSession = transcriber
    transcriber.onEvent = { event in
        switch event {
        case .ready(let engine):
            Log.info("Listening with \(engine) — speak; Ctrl-C to stop")
        case .volatile(let text):
            FileHandle.standardError.write(Data("\r\u{1B}[K… \(text)".utf8))
        case .final(let text):
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
            print("Heard: \(text)")
        case .failed(let message):
            Log.error(message)
            exit(1)
        case .level:
            break
        }
    }
    try await transcriber.start(locale: locale)
}

func runRelay(locale: Locale) throws {
    let descriptorURL = VoiceDescriptor.defaultURL
    let token = VoiceDescriptor.makeToken()
    let server = try VoiceServer(port: port, token: token)
    server.makeSession = {
        guard await microphoneAllowed() else { throw MacTranscriberError.microphoneDenied }
        return MacTranscriber()
    }

    func shutdown() -> Never {
        server.stop()
        VoiceDescriptor.remove(at: descriptorURL)
        Log.info("Voice relay stopped")
        exit(0)
    }
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    for signalNumber in [SIGINT, SIGTERM] {
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler { shutdown() }
        source.resume()
        signalSources.append(source)
    }

    server.start {
        do {
            try VoiceDescriptor.write(to: descriptorURL, port: server.port, token: token)
            Log.info("Listening on 127.0.0.1:\(server.port) (loopback only) · published \(descriptorURL.path)")
            Log.info("Ready — press and hold a target in Morpho, then speak")
        } catch {
            Log.error("Could not publish \(descriptorURL.path): \(error)")
            exit(73)
        }
    }
}

Task {
    do {
        guard SpeechTranscriber.isAvailable else {
            Log.error("SpeechTranscriber isn't available on this Mac")
            exit(69)
        }
        let locale = await MacTranscriber.locale()
        try await MacTranscriber.installAssets(locale: locale)
        switch mode {
        case "selftest":
            try await runSelfTest(phrase: selftestPhrase, locale: locale)
        case "listen":
            guard await microphoneAllowed() else { throw MacTranscriberError.microphoneDenied }
            try await runListen(locale: locale)
        default:
            // Ask for the microphone now, not mid-demo.
            guard await microphoneAllowed() else { throw MacTranscriberError.microphoneDenied }
            try runRelay(locale: locale)
        }
    } catch {
        Log.error("\(error)")
        exit(1)
    }
}

RunLoop.main.run()

// MARK: - Support

enum VoiceDescriptor {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Morpho/voice.json")
    }

    /// 256 bits from the system CSPRNG, hex-encoded.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed (\(status))")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func write(to url: URL, port: UInt16, token: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let payload: [String: Any] = [
            "version": VoiceWire.version,
            "port": Int(port),
            "token": token,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "startedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        // Create with owner-only permissions before any bytes land on disk.
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

enum Log {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func info(_ message: String) { emit("INFO ", message) }
    static func error(_ message: String) { emit("ERROR", message) }

    private static func emit(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
