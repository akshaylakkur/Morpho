//
//  ScoutView.swift
//  Morpho
//
//  Scout Mode (spec §4.3): compact view on the outer display. System vertical
//  bars carry symbol+title toolbar items; the viewfinder extends beneath them
//  via backgroundExtensionEffect(). Recording starts on the dual screen, so
//  Record here asks to unfold. While a take recorded on the dual screen is
//  running, the outer display holds the butterfly on black with
//  "Recording is in progress" and the take's timer.
//

import SwiftUI

struct ScoutView: View {
    @Environment(SessionModel.self) private var session
    @Environment(MorphoEngine.self) private var engine

    /// Brief, non-blocking hint shown when Record is pressed on the outer display.
    @State private var isShowingUnfoldHint = false
    @State private var hintDismissal: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                if session.isRecording {
                    recordingScreen
                        .transition(.opacity)
                } else {
                    // Hero viewfinder extends under the system vertical bars.
                    StageView(compact: true)
                        .backgroundExtensionEffect()
                }

                if isShowingUnfoldHint, !session.isRecording {
                    unfoldHint
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .ignoresSafeArea(edges: .vertical)
            .animation(.smooth, value: session.isRecording)
            .animation(.smooth, value: isShowingUnfoldHint)
            .toolbar {
                // The side icons step aside while the recording screen shows.
                if !session.isRecording {
                    // Record lives in the system vertical bar as a proper
                    // toolbar item: symbol + title, pinned so it never overflows.
                    ToolbarItem(placement: .topBarPinnedTrailing) {
                        Button("Record", systemImage: "record.circle") {
                            showUnfoldHint()
                        }
                    }

                    ToolbarItemGroup {
                        Button {
                            engine.flipCamera()
                        } label: {
                            Label("Flip Camera", systemImage: "arrow.trianglehead.2.clockwise.rotate.90.camera.fill")
                        }
                    }
                    .visibilityPriority(.high)

                    // Secondary controls live in the system overflow menu.
                    ToolbarOverflowMenu {
                        Button {
                            Task { await engine.exportLoopcast() }
                        } label: {
                            Label("Loopcast", systemImage: "arrow.trianglehead.2.counterclockwise.rotate.90")
                        }
                        Button {
                            _ = engine.captureStill()
                        } label: {
                            Label("Capture Still", systemImage: "camera.shutter.button")
                        }
                        if session.activeRealm != nil || session.lastCast != nil {
                            Button {
                                engine.clearRealm()
                            } label: {
                                Label("Clear Realm", systemImage: "arrow.uturn.backward")
                            }
                        }
                        sourceMenu
                    }
                }
            }
            // Unfolding swaps this view out; never leave the hint behind.
            .onDisappear {
                hintDismissal?.cancel()
                isShowingUnfoldHint = false
            }
        }
    }

    private var unfoldHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                .font(.title2)
            Text("Move to dual screen")
                .font(.headline)
            Text("Unfold your iPhone, then press Record.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private func showUnfoldHint() {
        isShowingUnfoldHint = true
        hintDismissal?.cancel()
        hintDismissal = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            isShowingUnfoldHint = false
        }
    }

    /// Shown on the outer display while a take is recording.
    private var recordingScreen: some View {
        ZStack {
            Color.black

            VStack(spacing: 14) {
                ButterflyCurtain(phase: .curtain, backdrop: .black)
                    .frame(width: 240, height: 200)

                Text("Recording is in progress")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)

                if let startedAt = session.recordingStartedAt {
                    SessionTimerChip(startedAt: startedAt, font: .title3.weight(.semibold))
                }
            }
            .padding(.horizontal, 24)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var sourceMenu: some View {
        Picker("Source", selection: sourceBinding) {
            ForEach(engine.availableSources(), id: \.self) { kind in
                Label(kind.displayName, systemImage: kind.symbol)
                    .tag(kind)
            }
        }
    }

    private var sourceBinding: Binding<VideoSourceKind> {
        Binding(
            get: { session.videoSource },
            set: { engine.selectSource($0) }
        )
    }
}
