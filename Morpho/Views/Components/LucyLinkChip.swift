//
//  LucyLinkChip.swift
//  Morpho
//
//  The Deck's Lucy control: which backend transforms the feed and what the
//  link is doing, with the session clock and (live only) the running cost.
//  Its menu switches backends — Live asks for confirmation every time — and
//  opens the Lucy Console.
//

import SwiftUI

struct LucyLinkChip: View {
    @Environment(SessionModel.self) private var session
    @Environment(MorphoEngine.self) private var engine

    @State private var confirmingLive = false
    @State private var showingConsole = false

    var body: some View {
        Menu {
            Picker("Lucy Backend", selection: modeSelection) {
                ForEach(LucyLinkMode.allCases) { mode in
                    Label {
                        Text(mode.displayName)
                        Text(mode.summary)
                    } icon: {
                        Image(systemName: mode.symbol)
                    }
                    .tag(mode)
                }
            }
            Divider()
            Button("Lucy Console", systemImage: "list.bullet.rectangle") {
                showingConsole = true
            }
        } label: {
            label
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .confirmationDialog("Go live with Lucy?", isPresented: $confirmingLive, titleVisibility: .visible) {
            Button("Go Live") {
                Task { await engine.lucy.setMode(.live) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(liveWarning)
        }
        .sheet(isPresented: $showingConsole) {
            LucyConsoleView()
        }
        .accessibilityLabel("Lucy: \(status.mode.displayName), \(status.phase.label)")
        .accessibilityHint("Choose the backend or open the Lucy Console")
    }

    private var status: LucyLinkStatus { session.lucy }

    private var modeSelection: Binding<LucyLinkMode> {
        Binding {
            session.lucy.mode
        } set: { mode in
            if mode == .live {
                confirmingLive = true
            } else {
                Task { await engine.lucy.setMode(mode) }
            }
        }
    }

    private var label: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Image(systemName: status.mode.symbol)
                .font(.caption.weight(.semibold))
            Text(caption)
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(Theme.chipSpring, value: caption)
    }

    private var caption: String {
        var parts = [status.mode.displayName]
        if status.mode.usesTransport {
            if status.phase.isInSession {
                parts.append(Self.clock(status.sessionSeconds))
            } else if status.phase != .idle {
                parts.append(status.phase.label)
            }
        }
        if status.mode == .live, status.liveSeconds > 0 {
            parts.append(status.estimatedLiveCost.formatted(.currency(code: "USD")))
        }
        return parts.joined(separator: " · ")
    }

    private var dotColor: Color {
        guard status.mode.usesTransport else { return .gray }
        switch status.phase {
        case .streaming: return Theme.connectedTeal
        case .connecting, .queued: return Theme.generatingAmber
        case .reconnecting, .failed: return Theme.reconnectingRed
        case .paused: return Theme.generatingAmber.opacity(0.6)
        case .idle: return .white.opacity(0.5)
        }
    }

    private var liveWarning: String {
        let perSecond = LucyLinkStatus.dollarsPerSecond.formatted(.currency(code: "USD"))
        let sessionMinutes = Int(engine.lucy.policy.sessionCapSeconds / 60)
        let launchMinutes = Int(engine.lucy.policy.liveLaunchCapSeconds / 60)
        let launchCost = (engine.lucy.policy.liveLaunchCapSeconds * LucyLinkStatus.dollarsPerSecond).formatted(.currency(code: "USD"))
        return "Decart bills about \(perSecond) per second while a session is open. A session opens only while something is cast, ends after \(sessionMinutes) minutes, and live use stops for this launch after \(launchMinutes) minutes (about \(launchCost))."
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
