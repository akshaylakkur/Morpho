//
//  LucyLink.swift
//  Morpho
//
//  The vocabulary of the Lucy link: which backend is transforming the feed,
//  where the link is, and the transport contract every backend implements.
//
//    simulated  the on-device look (SimulatedLucy); nothing leaves the app
//    rehearsal  the full live pipeline — frame uplink, prompt updates, acks,
//               output downlink, billing meter, caps — against a local
//               stand-in for Lucy. Free; use it to test everything.
//    live       Decart Lucy 2.5 Realtime. Billed per second; must be armed
//               by hand each launch and is never restored from disk.
//

import CoreGraphics
import CoreVideo
import Foundation

enum LucyLinkMode: String, CaseIterable, Identifiable, Sendable {
    case simulated
    case rehearsal
    case live

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simulated: "Simulated"
        case .rehearsal: "Rehearsal"
        case .live: "Live Lucy"
        }
    }

    var symbol: String {
        switch self {
        case .simulated: "wand.and.sparkles"
        case .rehearsal: "theatermasks"
        case .live: "bolt.fill"
        }
    }

    var summary: String {
        switch self {
        case .simulated: "On-device look · free"
        case .rehearsal: "Full pipeline, stand-in Lucy · free"
        case .live: "Decart Lucy 2.5 · billed per second"
        }
    }

    /// Whether frames and prompts go through a transport at all.
    var usesTransport: Bool { self != .simulated }
}

/// Why a wanted session isn't running.
enum LucyPauseReason: Equatable, Sendable {
    /// No camera frames for a while; resumes when they return.
    case feedStalled
    /// This session reached its length cap; resumes on request.
    case sessionCap
    /// Live Lucy reached this launch's spending cap; stays off.
    case launchCap

    var label: String {
        switch self {
        case .feedStalled: "Paused · no camera"
        case .sessionCap: "Paused · session limit"
        case .launchCap: "Stopped · spending limit"
        }
    }
}

enum LucyLinkPhase: Equatable, Sendable {
    /// Nothing is cast, so no session is open (and nothing is billed).
    case idle
    case connecting
    case queued(position: Int?)
    /// Connected; frames go up, transformed frames come back.
    case streaming
    case reconnecting
    case paused(LucyPauseReason)
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Standing by"
        case .connecting: "Connecting…"
        case .queued(let position): position.map { "Queued · #\($0)" } ?? "Queued…"
        case .streaming: "Streaming"
        case .reconnecting: "Reconnecting…"
        case .paused(let reason): reason.label
        case .failed: "Failed"
        }
    }

    /// A session exists (or is being opened) and may be billing.
    var isInSession: Bool {
        switch self {
        case .connecting, .queued, .streaming, .reconnecting: true
        case .idle, .paused, .failed: false
        }
    }
}

enum LucyPromptState: Equatable, Sendable {
    case none
    case sending
    case applied(at: Date)
    case failed(String)
}

struct LucyLogEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let at: Date
    let message: String
}

/// Everything the UI shows about the link; updated at human rates (≤ 1 Hz
/// for meters), never per frame.
struct LucyLinkStatus: Equatable, Sendable {
    var mode: LucyLinkMode = .simulated
    var phase: LucyLinkPhase = .idle
    /// What is applied (or will be, once the session opens).
    var directive: LucyDirective?
    var promptState: LucyPromptState = .none
    /// Generated seconds in the open session.
    var sessionSeconds: Double = 0
    /// Generated seconds of live Lucy this launch (what's billed).
    var liveSeconds: Double = 0
    var uplinkFPS: Double = 0
    var downlinkFPS: Double = 0
    var sessionsOpened = 0
    var promptsApplied = 0
    var log: [LucyLogEntry] = []

    static let dollarsPerSecond = 0.02
    static let logLimit = 60

    var estimatedLiveCost: Double { liveSeconds * Self.dollarsPerSecond }
}

/// Lucy 2.5's input shape: 1280×720 at 30 fps, landscape or portrait.
struct LucyStreamFormat: Equatable, Sendable {
    var width: Int
    var height: Int
    var fps: Int

    static let landscape = LucyStreamFormat(width: 1280, height: 720, fps: 30)
    static let portrait = LucyStreamFormat(width: 720, height: 1280, fps: 30)

    /// The orientation closest to the source's; frames are aspect-filled into it.
    static func matching(width: Int, height: Int) -> LucyStreamFormat {
        width >= height ? .landscape : .portrait
    }
}

enum LucyTransportEvent: Sendable {
    case connected
    case queued(position: Int?)
    case reconnecting
    /// The session ended on its own (not by `disconnect()`), with why.
    case ended(reason: String)
    /// Seconds generated so far in this session (what Decart bills).
    case generatedSeconds(Double)
    /// A transformed frame, delivered on the main actor.
    case output(CGImage)
}

enum LucyTransportError: LocalizedError {
    /// A newer prompt replaced this one before it was acknowledged.
    case superseded
    case notAvailable(String)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .superseded: "Superseded by a newer prompt"
        case .notAvailable(let why): why
        case .rejected(let why): why
        }
    }
}

/// One Lucy backend. All calls except `send` are made on the main actor.
@MainActor
protocol LucyTransport: AnyObject {
    /// Events, delivered on the main actor.
    var onEvent: ((LucyTransportEvent) -> Void)? { get set }

    /// Opens a session with `directive` already in place, so the first frame
    /// back is already transformed. `firstFrame` primes the uplink (a track
    /// must carry a frame before it can be published).
    func connect(format: LucyStreamFormat, directive: LucyDirective, firstFrame: CVPixelBuffer) async throws

    /// Uplink one frame, already in `format`. Called off the main actor.
    nonisolated func send(_ frame: CVPixelBuffer)

    /// Replace the prompt; returns once Lucy acknowledged it.
    func apply(_ directive: LucyDirective) async throws

    /// Close the session and stop billing.
    func disconnect() async
}
