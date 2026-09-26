//
//  TetherFrameSource.swift
//  Morpho
//
//  Tier 3 of the VideoSource ladder (spec §6.1): a USB-attached iPhone. The
//  Tools/MorphoTether helper on the Mac pulls the phone's video over the
//  cable and re-serves it on loopback; this source connects from inside the
//  simulator, presents the helper's per-launch token, and decodes its JPEG
//  frames. It never talks to anything beyond 127.0.0.1.
//
//  Wire format (mirrored in Tools/MorphoTether/Sources/MorphoTether/FrameServer.swift):
//    client → server : "MTH1" · u8 tokenLength · token bytes
//    server → client : "MTH1" · u8 status (1 = accepted)
//    then repeated   : u32 big-endian length · JPEG bytes
//

import CoreGraphics
import Foundation
import ImageIO
import Network

final class TetherFrameSource: VideoFrameSource {
    // MARK: Discovery

    /// Where the helper publishes its port and token, on the Mac's filesystem.
    static var descriptorURL: URL? {
        guard let hostHome = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else { return nil }
        return URL(fileURLWithPath: hostHome)
            .appending(path: "Library/Application Support/Morpho/tether.json")
    }

    /// True inside the simulator, where the Mac-side helper is reachable at all.
    static var isSupported: Bool { descriptorURL != nil }

    /// True while a helper is actually running.
    static var isDiscoverable: Bool { loadDescriptor() != nil }

    static func loadDescriptor() -> TetherDescriptor? {
        guard let url = descriptorURL,
              let data = try? Data(contentsOf: url),
              let descriptor = try? JSONDecoder().decode(TetherDescriptor.self, from: data),
              descriptor.version == TetherWire.version,
              descriptor.port > 0,
              isProcessAlive(descriptor.pid)
        else { return nil }
        return descriptor
    }

    /// The simulator runs as the same user as the helper, so a null signal is a valid liveness probe.
    private static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: State (everything below is touched only on `queue`)

    private let queue = DispatchQueue(label: "morpho.tether", qos: .userInteractive)
    private var connection: NWConnection?
    // Written and read only on `queue`; opting out of main-actor isolation is safe here.
    nonisolated(unsafe) private var handler: (@MainActor @Sendable (CGImage) -> Void)?
    private var stopped = true
    private var deliveryInFlight = false
    private var lastPayload: Data?
    private static let reconnectDelay: TimeInterval = 1

    func start(onFrame: @escaping @MainActor @Sendable (CGImage) -> Void) {
        queue.async {
            self.handler = onFrame
            self.stopped = false
            self.connect()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.handler = nil
            self.connection?.cancel()
            self.connection = nil
        }
    }

    // MARK: Connection

    private func connect() {
        guard !stopped, connection == nil else { return }
        guard let descriptor = Self.loadDescriptor(),
              let port = NWEndpoint.Port(rawValue: descriptor.port),
              let handshake = TetherWire.handshake(token: descriptor.token)
        else {
            scheduleReconnect()
            return
        }

        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        self.connection = connection
        lastPayload = nil
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                authenticate(with: handshake, on: connection)
            case .waiting, .failed, .cancelled:
                // A refused loopback connect surfaces as `.waiting`; we retry on our own clock.
                drop(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func authenticate(with handshake: Data, on connection: NWConnection) {
        connection.send(content: handshake, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            guard error == nil else {
                drop(connection)
                return
            }
            let ackLength = TetherWire.magic.count + 1
            connection.receive(minimumIncompleteLength: ackLength, maximumLength: ackLength) { [weak self] data, _, _, error in
                guard let self else { return }
                guard error == nil, let data, TetherWire.isAccepted(data) else {
                    drop(connection)
                    return
                }
                receiveFrame(on: connection)
            }
        })
    }

    private func receiveFrame(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, error in
            guard let self else { return }
            guard error == nil, let header, let length = TetherWire.frameLength(header) else {
                drop(connection)
                return
            }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] payload, _, _, error in
                guard let self else { return }
                guard error == nil, let payload, payload.count == length else {
                    drop(connection)
                    return
                }
                // A byte-identical repeat is the phone holding its last frame
                // (Continuity Camera's Pause). Withholding it lets the engine's
                // watchdog see the feed go quiet; a live sensor never repeats exactly.
                if payload != lastPayload {
                    lastPayload = payload
                    if let image = Self.decode(payload) {
                        deliver(image)
                    }
                }
                receiveFrame(on: connection)
            }
        }
    }

    private func drop(_ connection: NWConnection) {
        connection.cancel()
        guard self.connection === connection else { return }
        self.connection = nil
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + Self.reconnectDelay) { [weak self] in
            self?.connect()
        }
    }

    // MARK: Frames

    private static func decode(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        // Decode here, off the main actor, so the Stage only ever blits.
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    /// Hands a frame to the main actor, dropping it if the previous one is still being processed.
    private func deliver(_ image: CGImage) {
        guard let handler, !deliveryInFlight else { return }
        deliveryInFlight = true
        Task { @MainActor [weak self] in
            handler(image)
            self?.queue.async { self?.deliveryInFlight = false }
        }
    }
}

/// What the helper publishes so the app can find and authenticate to it.
struct TetherDescriptor: Decodable, Equatable {
    var version: Int
    var port: UInt16
    var token: String
    var pid: Int32
    var device: String?
}

/// Wire format shared with the helper; keep both sides in sync.
enum TetherWire {
    static let version = 1
    static let magic = Data("MTH1".utf8)
    /// Sanity ceiling for a single frame; anything larger means a corrupt stream.
    static let maxFrameBytes = 24 * 1024 * 1024

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

    static func frameLength(_ header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let length = UInt32(bigEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard length > 0, length <= maxFrameBytes else { return nil }
        return Int(length)
    }
}
