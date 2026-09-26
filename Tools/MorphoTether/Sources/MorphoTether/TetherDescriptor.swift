//
//  TetherDescriptor.swift
//  MorphoTether
//
//  Publishes where the relay lives (port) and the secret needed to read it
//  (token) in a file only this user can read. Morpho, running inside the
//  simulator as the same user, reads it via SIMULATOR_HOST_HOME.
//

import Foundation
import Security

enum TetherDescriptor {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Morpho/tether.json")
    }

    /// 256 bits from the system CSPRNG, hex-encoded.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed (\(status))")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func write(to url: URL, port: UInt16, token: String, device: String?) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let payload: [String: Any] = [
            "version": TetherWire.version,
            "port": Int(port),
            "token": token,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "device": device ?? NSNull(),
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
