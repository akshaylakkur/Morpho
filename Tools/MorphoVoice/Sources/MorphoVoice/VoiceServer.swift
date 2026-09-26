//
//  VoiceServer.swift
//  MorphoVoice
//
//  Loopback-only TCP server. A client opens a connection and presents the
//  per-launch token; if it matches, the Mac's microphone opens for exactly
//  as long as that connection stays open, and every transcription event is
//  sent back as one line of JSON. One listener at a time: a newer client
//  takes the microphone from an older one.
//
//  Wire format (mirrored in Morpho/Alchemist/HostVoiceRelay.swift):
//    client → server : "MVC1" · u8 tokenLength · token bytes
//    server → client : "MVC1" · u8 status (1 = accepted)
//    then repeated   : one JSON object per line, UTF-8, "\n"-terminated:
//      {"event":"ready","engine":"…"}      microphone open, transcriber running
//      {"event":"level","value":0.42}      mic amplitude 0…1
//      {"event":"volatile","text":"…"}     words still settling
//      {"event":"final","text":"…"}        a finished utterance segment
//      {"event":"error","message":"…"}     the session failed; the server hangs up
//

import Foundation
import Network

enum VoiceWire {
    static let version = 1
    static let magic = Data("MVC1".utf8)

    static func acknowledgement(accepted: Bool) -> Data {
        var data = magic
        data.append(accepted ? 1 : 0)
        return data
    }

    static func line(_ fields: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }
}

final class VoiceServer {
    private final class Client {
        let connection: NWConnection
        var authenticated = false
        var transcriber: MacTranscriber?

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    /// Opens a transcription session for an authenticated client.
    var makeSession: (() async throws -> MacTranscriber)?

    private let queue = DispatchQueue(label: "morpho.voice.server")
    private let listener: NWListener
    private let token: Data
    private var clients: [ObjectIdentifier: Client] = [:]
    private(set) var port: UInt16 = 0

    init(port: UInt16, token: String) throws {
        self.token = Data(token.utf8)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Bind to the loopback interface only: nothing is reachable from the LAN.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        listener = try NWListener(using: parameters)
    }

    func start(onReady: @escaping () -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                port = listener.port?.rawValue ?? 0
                onReady()
            case .failed(let error):
                Log.error("Listener failed: \(error)")
                exit(70)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            for client in clients.values {
                client.transcriber?.stop()
                client.connection.cancel()
            }
            clients.removeAll()
            listener.cancel()
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection)
        clients[ObjectIdentifier(client)] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .ready:
                readHandshake(client)
            case .failed, .cancelled:
                remove(client)
            default:
                break
            }
        }
        connection.start(queue: queue)

        // Peers that don't authenticate promptly are dropped.
        queue.asyncAfter(deadline: .now() + 3) { [weak client] in
            if let client, !client.authenticated { client.connection.cancel() }
        }
    }

    private func readHandshake(_ client: Client) {
        let headLength = VoiceWire.magic.count + 1
        client.connection.receive(minimumIncompleteLength: headLength, maximumLength: headLength) { [weak self] head, _, _, _ in
            guard let self, let head, head.count == headLength, head.prefix(VoiceWire.magic.count) == VoiceWire.magic else {
                client.connection.cancel()
                return
            }
            let tokenLength = Int(head[head.startIndex + VoiceWire.magic.count])
            guard tokenLength > 0 else {
                client.connection.cancel()
                return
            }
            client.connection.receive(minimumIncompleteLength: tokenLength, maximumLength: tokenLength) { [weak self] body, _, _, _ in
                guard let self else { return }
                guard let body, Self.constantTimeEquals(body, token) else {
                    Log.info("Rejected a client with a bad token")
                    client.connection.send(content: VoiceWire.acknowledgement(accepted: false), completion: .contentProcessed { _ in
                        client.connection.cancel()
                    })
                    return
                }
                client.authenticated = true
                client.connection.send(content: VoiceWire.acknowledgement(accepted: true), completion: .contentProcessed { _ in })
                // The microphone belongs to the newest listener.
                for other in clients.values where other !== client && other.authenticated {
                    other.connection.cancel()
                }
                watchForHangUp(client)
                openSession(for: client)
            }
        }
    }

    /// The client never sends anything after the handshake; a read that
    /// completes means it hung up.
    private func watchForHangUp(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { [weak self, weak client] _, _, isComplete, error in
            guard let self, let client else { return }
            if isComplete || error != nil {
                client.connection.cancel()
            } else {
                watchForHangUp(client)
            }
        }
    }

    private func openSession(for client: Client) {
        guard let makeSession else { return }
        Task {
            do {
                let transcriber = try await makeSession()
                transcriber.onEvent = { [weak self, weak client] event in
                    guard let self, let client else { return }
                    queue.async { self.send(event, to: client) }
                }
                let stillConnected = queue.sync { clients[ObjectIdentifier(client)] != nil }
                guard stillConnected else { return }
                queue.sync { client.transcriber = transcriber }
                try await transcriber.start(locale: MacTranscriber.locale())
                Log.info("Listening on the Mac microphone")
            } catch {
                Log.error("Could not start listening: \(error)")
                queue.async {
                    client.connection.send(content: VoiceWire.line(["event": "error", "message": "\(error)"]), completion: .contentProcessed { _ in
                        client.connection.cancel()
                    })
                }
            }
        }
    }

    private func send(_ event: MacTranscriber.Event, to client: Client) {
        guard clients[ObjectIdentifier(client)] != nil else { return }
        let line: Data
        switch event {
        case .ready(let engine):
            line = VoiceWire.line(["event": "ready", "engine": engine])
        case .level(let value):
            line = VoiceWire.line(["event": "level", "value": Double(value)])
        case .volatile(let text):
            line = VoiceWire.line(["event": "volatile", "text": text])
        case .final(let text):
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { Log.info("Heard: \(text)") }
            line = VoiceWire.line(["event": "final", "text": text])
        case .failed(let message):
            Log.error(message)
            client.connection.send(content: VoiceWire.line(["event": "error", "message": message]), completion: .contentProcessed { _ in
                client.connection.cancel()
            })
            return
        }
        client.connection.send(content: line, completion: .contentProcessed { _ in })
    }

    private func remove(_ client: Client) {
        guard clients.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
        if let transcriber = client.transcriber {
            client.transcriber = nil
            transcriber.stop()
            Log.info("Microphone closed")
        }
    }

    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}
