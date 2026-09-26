//
//  TokenService.swift
//  Morpho
//
//  Mints short-lived Decart tokens from the Supabase Edge Function (spec §6):
//  no permanent key ships in the app. Falls back to a direct dev key when a
//  TOKEN_ENDPOINT isn't configured yet.
//

import Foundation

/// Plain value; opting out of default actor isolation so the `TokenService`
/// actor can read it without hopping to the main actor.
nonisolated struct EphemeralToken: Sendable {
    let value: String
    let expiresAt: Date

    var isFresh: Bool { expiresAt.timeIntervalSinceNow > 30 }
}

enum TokenServiceError: Error {
    case notConfigured
    case badResponse
}

actor TokenService {
    private let credentials: MorphoCredentials
    private var cached: EphemeralToken?

    init(credentials: MorphoCredentials) {
        self.credentials = credentials
    }

    /// Returns a token suitable for `DecartConfiguration(apiKey:)`.
    func currentToken() async throws -> String {
        if let cached, cached.isFresh {
            return cached.value
        }
        if let endpoint = credentials.tokenEndpoint {
            let token = try await mint(from: endpoint)
            cached = token
            return token.value
        }
        // Dev-only fallback while the edge function isn't deployed.
        if let devKey = credentials.decartAPIKey {
            return devKey
        }
        throw TokenServiceError.notConfigured
    }

    private func mint(from endpoint: URL) async throws -> EphemeralToken {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        if let anonKey = credentials.supabaseAnonKey {
            request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TokenServiceError.badResponse
        }
        // Expected edge-function payload: { "token": "...", "expires_in": 3600 }
        struct Payload: Decodable {
            let token: String
            let expiresIn: TimeInterval?
            enum CodingKeys: String, CodingKey {
                case token
                case expiresIn = "expires_in"
            }
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return EphemeralToken(
            value: payload.token,
            expiresAt: .now.addingTimeInterval(payload.expiresIn ?? 3300)
        )
    }
}
