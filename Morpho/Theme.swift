//
//  Theme.swift
//  Morpho
//
//  Shared colors, materials, and motion constants.
//

import SwiftUI

enum Theme {
    // Connection orb palette (spec §4.1: breathing teal / pulsing amber / heartbeat red).
    static let connectedTeal = Color(red: 0.15, green: 0.85, blue: 0.78)
    static let generatingAmber = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let reconnectingRed = Color(red: 1.0, green: 0.30, blue: 0.32)

    // Morpho's iridescent identity gradient (butterfly mark, transmutation sweep).
    static let iridescent = LinearGradient(
        colors: [
            Color(red: 0.35, green: 0.80, blue: 1.0),
            Color(red: 0.62, green: 0.48, blue: 1.0),
            Color(red: 0.95, green: 0.55, blue: 0.90),
            Color(red: 0.35, green: 0.95, blue: 0.80),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let stageBackground = Color(red: 0.04, green: 0.05, blue: 0.08)

    // Motion spec (§7): every animation small, purposeful, ≤600ms.
    static let sweepDuration: TimeInterval = 0.6
    static let unfoldSpring = Animation.spring(response: 0.55, dampingFraction: 0.82)
    static let chipSpring = Animation.spring(response: 0.35, dampingFraction: 0.75)
    static let deckCascadeStagger: TimeInterval = 0.04
    /// The one deliberate exception to ≤600ms: the reveal is a moment, not a transition.
    static let stageRevealDuration: TimeInterval = 1.25
}
