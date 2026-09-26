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
        let payload = try JSONDecoder().decode(TokenPayload.self, from: data)
        return EphemeralToken(value: payload.value, expiresAt: payload.expiry(now: .now))
    }
}

/// Accepts Decart's own client-token shape (`{ "apiKey", "expiresAt" }`, what
/// `POST /v1/client/tokens` returns) or the older edge-function shape
/// (`{ "token", "expires_in" }`).
nonisolated struct TokenPayload: Decodable, Sendable {
    var value: String
    var expiresAt: Date?
    var expiresIn: TimeInterval?

    /// Decart's default token lifetime when the response doesn't say.
    static let defaultLifetime: TimeInterval = 60

    private enum CodingKeys: String, CodingKey {
        case apiKey, expiresAt, token
        case expiresIn = "expires_in"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) {
            value = apiKey
        } else {
            value = try container.decode(String.self, forKey: .token)
        }
        expiresIn = try container.decodeIfPresent(TimeInterval.self, forKey: .expiresIn)
        if let raw = try container.decodeIfPresent(String.self, forKey: .expiresAt) {
            expiresAt = Self.parseDate(raw)
        } else if let seconds = try? container.decodeIfPresent(Double.self, forKey: .expiresAt) {
            // Epoch seconds (or milliseconds).
            expiresAt = Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
    }

    func expiry(now: Date) -> Date {
        if let expiresAt { return expiresAt }
        return now.addingTimeInterval(expiresIn ?? Self.defaultLifetime)
    }

    private static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
