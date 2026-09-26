//
//  FrameServer.swift
//  MorphoTether
//
//  Loopback-only TCP server. A client opens a connection, sends the magic
//  plus the per-launch token, and — only if it matches — receives a stream
//  of length-prefixed JPEG frames. Slow clients drop frames rather than
//  building up latency.
//
//  Wire format (mirrored in Morpho/Decart/TetherFrameSource.swift):
//    client → server : "MTH1" · u8 tokenLength · token bytes
//    server → client : "MTH1" · u8 status (1 = accepted)
//    then repeated   : u32 big-endian length · JPEG bytes
//

import Foundation
import Network

enum TetherWire {
    static let version = 1
    static let magic = Data("MTH1".utf8)

    static func frameHeader(length: Int) -> Data {
        var bigEndian = UInt32(length).bigEndian
        return Data(bytes: &bigEndian, count: 4)
    }

    static func acknowledgement(accepted: Bool) -> Data {
        var data = magic
        data.append(accepted ? 1 : 0)
        return data
    }
}

final class FrameServer {
    private final class Client {
        let connection: NWConnection
        var authenticated = false
        var sending = false

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private let queue = DispatchQueue(label: "morpho.tether.server")
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

    var clientCount: Int {
        queue.sync { clients.values.filter(\.authenticated).count }
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
            for client in clients.values { client.connection.cancel() }
            clients.removeAll()
            listener.cancel()
        }
    }

    /// Fan one encoded frame out to every authenticated client that is ready for it.
    func broadcast(_ payload: Data) {
        queue.async {
            let header = TetherWire.frameHeader(length: payload.count)
            for client in self.clients.values where client.authenticated && !client.sending {
                client.sending = true
                client.connection.send(content: header + payload, completion: .contentProcessed { [weak client] error in
                    client?.sending = false
                    if error != nil { client?.connection.cancel() }
                })
            }
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
        let headLength = TetherWire.magic.count + 1
        client.connection.receive(minimumIncompleteLength: headLength, maximumLength: headLength) { [weak self] head, _, _, _ in
            guard let self, let head, head.count == headLength, head.prefix(TetherWire.magic.count) == TetherWire.magic else {
                client.connection.cancel()
                return
            }
            let tokenLength = Int(head[head.startIndex + TetherWire.magic.count])
            guard tokenLength > 0 else {
                client.connection.cancel()
                return
            }
            client.connection.receive(minimumIncompleteLength: tokenLength, maximumLength: tokenLength) { [weak self] body, _, _, _ in
                guard let self else { return }
                guard let body, Self.constantTimeEquals(body, token) else {
                    Log.info("Rejected a client with a bad token")
                    client.connection.send(content: TetherWire.acknowledgement(accepted: false), completion: .contentProcessed { _ in
                        client.connection.cancel()
                    })
                    return
                }
                client.authenticated = true
                client.connection.send(content: TetherWire.acknowledgement(accepted: true), completion: .contentProcessed { _ in })
                Log.info("Client connected (\(clients.values.filter(\.authenticated).count) streaming)")
            }
        }
    }

    private func remove(_ client: Client) {
        if clients.removeValue(forKey: ObjectIdentifier(client)) != nil, client.authenticated {
            Log.info("Client disconnected (\(clients.values.filter(\.authenticated).count) streaming)")
        }
    }

    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}
