//
//  LucyConsoleView.swift
//  Morpho
//
//  A look inside the Lucy link for testing: the exact prompt Lucy holds
//  (every cast in effect, within the 750-character budget), whether it was
//  acknowledged, frame rates both ways, the billing meter against its caps,
//  and a log of everything the director did.
//

import SwiftUI

struct LucyConsoleView: View {
    @Environment(SessionModel.self) private var session
    @Environment(MorphoEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                linkSection
                castsSection
                promptSection
                metersSection
                actionsSection
                logSection
            }
            .navigationTitle("Lucy Console")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var status: LucyLinkStatus { session.lucy }

    // MARK: Sections

    private var linkSection: some View {
        Section("Link") {
            LabeledContent("Backend", value: status.mode.displayName)
            LabeledContent("Session", value: phaseText)
            LabeledContent("Prompt", value: promptStateText)
            LabeledContent("Sessions opened", value: "\(status.sessionsOpened)")
            LabeledContent("Prompts applied", value: "\(status.promptsApplied)")
        }
    }

    /// Everything applied right now; each stays until removed here.
    @ViewBuilder
    private var castsSection: some View {
        if session.hasAnyCast {
            Section {
                if let scene = session.lastCast {
                    Label(session.activeRealm?.name ?? scene.editType.displayName, systemImage: "photo")
                }
                ForEach(session.augmentations) { augmentation in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(augmentation.shortTitle)
                            Text("\(augmentation.target.label) · “\(augmentation.rawSpeech)”")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "scope")
                    }
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            engine.removeAugmentation(augmentation)
                        }
                    }
                }
                Button("Clear All", systemImage: "xmark.circle", role: .destructive) {
                    engine.clearRealm()
                }
            } header: {
                Text("Casts in effect")
            } footer: {
                Text("Swipe a cast to remove it. Clearing everything closes the Lucy session.")
            }
        }
    }

    @ViewBuilder
    private var promptSection: some View {
        Section {
            if let directive = status.directive {
                Text(directive.text)
                    .font(.callout)
                    .textSelection(.enabled)
                ForEach(directive.parts) { part in
                    Label {
                        Text(part.title)
                    } icon: {
                        Image(systemName: part.kind == .scene ? "photo" : "scope")
                    }
                    .font(.subheadline)
                }
                if !directive.droppedTitles.isEmpty {
                    Label("Left out for length: \(directive.droppedTitles.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Enhance", value: directive.enrich ? "On" : "Off")
                LabeledContent("Reference image", value: directive.referenceImageData.map { "\($0.count / 1024) KB" } ?? "None")
            } else {
                Text("Nothing is cast. Press and hold an object on the viewfinder and say what to change.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Prompt Lucy holds")
                Spacer()
                if let directive = status.directive {
                    Text("\(directive.text.count) / \(LucyPromptSpec.maxLength)")
                        .monospacedDigit()
                }
            }
        } footer: {
            Text("Every cast still in effect is in this one prompt, so each augmentation keeps applying — and follows its object — until you remove it.")
        }
    }

    private var metersSection: some View {
        Section("Meters") {
            LabeledContent("Uplink", value: "\(Int(status.uplinkFPS)) fps")
            LabeledContent("Downlink", value: "\(Int(status.downlinkFPS)) fps")
            LabeledContent(
                "This session",
                value: "\(LucyLinkChip.clock(status.sessionSeconds)) of \(LucyLinkChip.clock(engine.lucy.policy.sessionCapSeconds))"
            )
            LabeledContent(
                "Live this launch",
                value: "\(LucyLinkChip.clock(status.liveSeconds)) of \(LucyLinkChip.clock(engine.lucy.policy.liveLaunchCapSeconds))"
            )
            LabeledContent("Estimated live cost", value: status.estimatedLiveCost.formatted(.currency(code: "USD")))
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            Button("Resend Prompt", systemImage: "arrow.clockwise") {
                engine.lucy.resendPrompt()
            }
            .disabled(status.phase != .streaming)

            Button("Resume Session", systemImage: "play.fill") {
                engine.lucy.resume()
            }
            .disabled(!canResume)

            Button("End Session", systemImage: "stop.fill", role: .destructive) {
                Task { await engine.lucy.endSession() }
            }
            .disabled(!status.phase.isInSession)

            if status.mode == .rehearsal {
                Button("Simulate Network Drop", systemImage: "wifi.exclamationmark") {
                    engine.lucy.simulateDrop()
                }
                .disabled(status.phase != .streaming)
            }
        }
    }

    private var logSection: some View {
        Section("Log") {
            if status.log.isEmpty {
                Text("No events yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(status.log) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.message)
                        .font(.subheadline)
                    Text(entry.at, format: .dateTime.hour().minute().second())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Copy

    private var canResume: Bool {
        guard status.directive != nil, status.mode.usesTransport else { return false }
        switch status.phase {
        case .paused(.sessionCap), .failed: return true
        default: return false
        }
    }

    private var phaseText: String {
        if case .failed(let reason) = status.phase { return "Failed · \(reason)" }
        return status.phase.label
    }

    private var promptStateText: String {
        switch status.promptState {
        case .none: "—"
        case .sending: "Sending…"
        case .applied(let at): "Applied \(at.formatted(.dateTime.hour().minute().second()))"
        case .failed(let reason): "Failed · \(reason)"
        }
    }
}
