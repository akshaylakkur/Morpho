//
//  HostVoiceRelay.swift
//  Morpho
//
//  Speech tier 0 in the simulator. The simulated device can open the Mac's
//  microphone but can't run a speech model on it, so the Tools/MorphoVoice
//  helper listens and transcribes on the Mac and streams the words here over
//  loopback. The Mac's microphone is open exactly as long as this
//  connection is. It never talks to anything beyond 127.0.0.1.
//
//  Wire format (mirrored in Tools/MorphoVoice/Sources/MorphoVoice/VoiceServer.swift):
//    client → server : "MVC1" · u8 tokenLength · token bytes
//    server → client : "MVC1" · u8 status (1 = accepted)
//    then repeated   : one JSON object per line ("\n"-terminated), with
//                      "event" = ready | level | volatile | final | error
//

import Foundation
import Network

final class HostVoiceRelay {
    enum Event: Equatable {
        case level(Float)
        case volatile(String)
        case final(String)
        /// The relay went away or its transcriber failed; the connection is closed.
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?

    // MARK: Discovery

    /// Where the helper publishes its port and token, on the Mac's filesystem.
    static var descriptorURL: URL? {
        guard let hostHome = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else { return nil }
        return URL(fileURLWithPath: hostHome)
            .appending(path: "Library/Application Support/Morpho/voice.json")
    }

    /// True while a helper is actually running on the Mac.
    static var isDiscoverable: Bool { loadDescriptor() != nil }

    static func loadDescriptor() -> HostVoiceDescriptor? {
        guard let url = descriptorURL,
              let data = try? Data(contentsOf: url),
              let descriptor = try? JSONDecoder().decode(HostVoiceDescriptor.self, from: data),
              descriptor.version == VoiceWire.version,
              descriptor.port > 0,
              descriptor.pid > 0,
              kill(descriptor.pid, 0) == 0 || errno == EPERM
        else { return nil }
        return descriptor
    }

    // MARK: State (the connection runs on the main queue; traffic is a few lines a second)

    private var connection: NWConnection?
    private var pendingStart: CheckedContinuation<String, Error>?
    private var received = Data()
    private static let startTimeout: Duration = .seconds(10)

    /// Connects, which opens the Mac's microphone, and returns once the
    /// transcriber there is listening. Returns the engine's description.
    func start() async throws -> String {
        guard let descriptor = Self.loadDescriptor(),
              let port = NWEndpoint.Port(rawValue: descriptor.port),
              let handshake = VoiceWire.handshake(token: descriptor.token)
        else { throw HostVoiceRelayError.notRunning }

        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        self.connection = connection
        received = Data()

        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.startTimeout)
            guard !Task.isCancelled else { return }
            self?.finishStart(.failure(HostVoiceRelayError.timedOut))
        }
        defer { timeout.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            pendingStart = continuation
            connection.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, self.connection === connection else { return }
                    switch state {
                    case .ready:
                        self.authenticate(with: handshake, on: connection)
                    case .waiting(let error), .failed(let error):
                        self.fail("Mac voice relay unreachable (\(error.localizedDescription))")
                    default:
                        break
                    }
                }
            }
            connection.start(queue: .main)
        }
    }

    /// Hangs up, which closes the Mac's microphone.
    func stop() {
        finishStart(.failure(CancellationError()))
        onEvent = nil
        connection?.cancel()
        connection = nil
    }

    // MARK: Connection

    private func authenticate(with handshake: Data, on connection: NWConnection) {
        connection.send(content: handshake, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    self.fail("Mac voice relay handshake failed (\(error.localizedDescription))")
                    return
                }
                let ackLength = VoiceWire.magic.count + 1
                connection.receive(minimumIncompleteLength: ackLength, maximumLength: ackLength) { [weak self] data, _, _, _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        guard let data, VoiceWire.isAccepted(data) else {
                            self.fail("Mac voice relay refused the connection")
                            return
                        }
                        self.receiveLines(on: connection)
                    }
                }
            }
        })
    }

    private func receiveLines(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, self.connection === connection else { return }
                if let data { self.received.append(data) }
                while let newline = self.received.firstIndex(of: 0x0A) {
                    let line = self.received[self.received.startIndex..<newline]
                    self.received.removeSubrange(self.received.startIndex...newline)
                    self.handle(line)
                }
                guard self.connection === connection else { return }
                if isComplete || error != nil {
                    self.fail("Mac voice relay disconnected")
                } else if self.received.count > VoiceWire.maxLineBytes {
                    self.fail("Mac voice relay sent a malformed stream")
                } else {
                    self.receiveLines(on: connection)
                }
            }
        }
    }

    private func handle(_ line: Data) {
        guard let message = try? JSONDecoder().decode(VoiceWire.Message.self, from: line) else { return }
        switch message.event {
        case "ready":
            finishStart(.success(message.engine ?? "Mac transcriber"))
        case "level":
            onEvent?(.level(message.value ?? 0))
        case "volatile":
            onEvent?(.volatile(message.text ?? ""))
        case "final":
            onEvent?(.final(message.text ?? ""))
        case "error":
            fail(message.message ?? "Mac voice relay failed")
        default:
            break
        }
    }

    /// Ends the connection; before `start` returns this throws from it, after it's an event.
    private func fail(_ reason: String) {
        connection?.cancel()
        connection = nil
        if pendingStart != nil {
            finishStart(.failure(HostVoiceRelayError.failed(reason)))
        } else {
            let onEvent = self.onEvent
            self.onEvent = nil
            onEvent?(.failed(reason))
        }
    }

    private func finishStart(_ result: Result<String, Error>) {
        guard let pendingStart else { return }
        self.pendingStart = nil
        if case .failure = result {
            connection?.cancel()
            connection = nil
        }
        pendingStart.resume(with: result)
    }
}

/// What the helper publishes so the app can find and authenticate to it.
struct HostVoiceDescriptor: Decodable, Equatable {
    var version: Int
    var port: UInt16
    var token: String
    var pid: Int32
}

enum HostVoiceRelayError: LocalizedError {
    case notRunning
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: "Mac voice relay isn't running (Tools/voice.sh)"
        case .timedOut: "Mac voice relay didn't start listening in time"
        case .failed(let reason): reason
        }
    }
}

/// Wire format shared with the helper; keep both sides in sync.
enum VoiceWire {
    static let version = 1
    static let magic = Data("MVC1".utf8)
    /// Sanity ceiling for one unterminated line; anything larger means a corrupt stream.
    static let maxLineBytes = 64 * 1024

    struct Message: Decodable {
        var event: String
        var text: String?
        var value: Float?
        var engine: String?
        var message: String?
    }

    static func handshake(token: String) -> Data? {
        let tokenBytes = Data(token.utf8)
        guard (1...255).contains(tokenBytes.count) else { return nil }
        var data = magic
        data.append(UInt8(tokenBytes.count))
        data.append(tokenBytes)
        return data
    }

    static func isAccepted(_ acknowledgement: Data) -> Bool {
        guard acknowledgement.count == magic.count + 1,
              acknowledgement.prefix(magic.count) == magic
        else { return false }
        return acknowledgement[acknowledgement.startIndex + magic.count] == 1
    }
}
