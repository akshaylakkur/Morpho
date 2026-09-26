//
//  SessionModel.swift
//  Morpho
//
//  The single observable session state (spec §10): connection, active Realm,
//  spellbook, recording, rig parameters. Services mutate it; views observe it.
//

import SwiftUI
import Observation

enum ConnectionPhase: String, Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case generating
    case reconnecting

    var orbColor: Color {
        switch self {
        case .connected: Theme.connectedTeal
        case .generating, .connecting: Theme.generatingAmber
        case .reconnecting: Theme.reconnectingRed
        case .disconnected: .gray
        }
    }

    var label: String {
        switch self {
        case .disconnected: "Offline"
        case .connecting: "Tuning…"
        case .connected: "Live"
        case .generating: "Generating"
        case .reconnecting: "Re-tuning reality"
        }
    }
}

enum MicMode: Equatable, Sendable {
    case idle
    case holdToTalk
    case openMic
}

/// What the Stage is showing (spec §7): the resting butterfly, the reveal,
/// the live viewfinder, or the reveal running in reverse.
enum StagePhase: Equatable, Sendable {
    case curtain
    case opening
    case live
    case closing
}

/// Tier switch (spec §6.1/§13): bundled clip is guaranteed, the device camera
/// needs hardware, and the tether needs the Mac-side relay (Tools/tether.sh).
enum VideoSourceKind: String, CaseIterable, Equatable, Sendable {
    case bundledClip
    case localCamera
    case tether

    var displayName: String {
        switch self {
        case .bundledClip: "Demo Clip"
        case .localCamera: "Camera"
        case .tether: "iPhone Tether"
        }
    }

    var symbol: String {
        switch self {
        case .bundledClip: "film.fill"
        case .localCamera: "camera.fill"
        case .tether: "cable.connector"
        }
    }
}

@Observable
final class SessionModel {
    // MARK: Connection
    var connection: ConnectionPhase = .disconnected

    // MARK: Realms & casting
    var activeRealm: Realm?
    var spellbook: [Incantation] = []
    /// The most recently cast prompt (drives the Stage's state chrome).
    var lastCast: LucyPromptSpec?
    /// Incremented on every cast; the Stage observes it to fire the transmutation sweep.
    var sweepTrigger = 0

    // MARK: Voice
    var micMode: MicMode = .idle
    var liveTranscript = ""
    /// Compiled prompt flashed in the Incantation overlay just before casting (spec §5).
    var compiledPreview: LucyPromptSpec?
    var micAmplitude: Float = 0
    var alchemistAvailable = false

    // MARK: Rig
    var selfAnchor = true
    var enhance = true
    var seed: UInt32 = .random(in: 0...UInt32.max)
    var seedLocked = false
    var torchOn = false
    var zoom: CGFloat = 1.0
    var usesFrontCamera = true
    var referenceImageData: Data?

    // MARK: Stage
    /// The butterfly holds the Stage until the first Record.
    var stagePhase: StagePhase = .curtain
    /// True once Record has been pressed; an armed Stage reopens by itself when the feed returns.
    var stageArmed = false

    // MARK: Recording & the Reel (spec §9)
    var isRecording = false
    var recordingStartedAt: Date?
    var lastExportURL: URL?
    /// Every take, newest first.
    var reel: [Clip] = []

    // MARK: Rift Slider (1.0 = fully transformed, 0.0 = fully original)
    var riftFraction: CGFloat = 1.0

    // MARK: Source tier
    var videoSource: VideoSourceKind = .bundledClip

    // MARK: Mutations

    func recordCast(rawSpeech: String, spec: LucyPromptSpec) {
        lastCast = spec
        sweepTrigger += 1
        if let index = spellbook.firstIndex(where: { $0.spec == spec }) {
            spellbook[index].recastCount += 1
        } else {
            spellbook.insert(Incantation(rawSpeech: rawSpeech, spec: spec), at: 0)
        }
    }

    func rerollSeedIfUnlocked() {
        guard !seedLocked else { return }
        seed = .random(in: 0...UInt32.max)
    }

    var recordingElapsed: TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return Date.now.timeIntervalSince(recordingStartedAt)
    }
}
