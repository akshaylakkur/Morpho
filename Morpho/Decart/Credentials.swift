//
//  Credentials.swift
//  Morpho
//
//  Central place where every key/endpoint lands (spec §6). The app is fully
//  functional without any of them (simulated Lucy over the bundled/synthetic
//  clip); each credential that appears unlocks the next tier.
//
//  ── TO GO LIVE, add a `Secrets.plist` to the app target with any of: ──
//    TOKEN_ENDPOINT   String  Supabase Edge Function URL that mints Decart
//                             ephemeral tokens (preferred for the event).
//    SUPABASE_ANON_KEY String Sent as `Authorization: Bearer …` to the edge fn.
//    DECART_API_KEY   String  Direct API key — DEV ONLY fallback, never ship.
//    LIVEKIT_URL      String  Reserved for a wireless tether; the USB tether
//    LIVEKIT_TOKEN    String  (Tools/tether.sh) needs neither.
//

import Foundation

struct MorphoCredentials: Sendable {
    var tokenEndpoint: URL?
    var supabaseAnonKey: String?
    var decartAPIKey: String?
    var liveKitURL: URL?
    var liveKitToken: String?

    /// True when any Decart auth path is configured.
    var canReachDecart: Bool { tokenEndpoint != nil || decartAPIKey != nil }

    static func load(bundle: Bundle = .main) -> MorphoCredentials {
        var credentials = MorphoCredentials()
        guard
            let url = bundle.url(forResource: "Secrets", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return credentials
        }
        if let raw = plist["TOKEN_ENDPOINT"] as? String { credentials.tokenEndpoint = URL(string: raw) }
        credentials.supabaseAnonKey = plist["SUPABASE_ANON_KEY"] as? String
        credentials.decartAPIKey = plist["DECART_API_KEY"] as? String
        if let raw = plist["LIVEKIT_URL"] as? String { credentials.liveKitURL = URL(string: raw) }
        credentials.liveKitToken = plist["LIVEKIT_TOKEN"] as? String
        return credentials
    }
}
