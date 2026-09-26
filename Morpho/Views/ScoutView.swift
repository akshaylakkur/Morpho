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

    @State private var isShowingUnfoldPrompt = false

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
            }
            .ignoresSafeArea(edges: .vertical)
            .animation(.smooth, value: session.isRecording)
            .toolbar {
                // The side icons step aside while the recording screen shows.
                if !session.isRecording {
                    // Record lives in the system vertical bar as a proper
                    // toolbar item: symbol + title, pinned so it never overflows.
                    ToolbarItem(placement: .topBarPinnedTrailing) {
                        Button("Record", systemImage: "record.circle") {
                            isShowingUnfoldPrompt = true
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
            .alert("Open to Record", isPresented: $isShowingUnfoldPrompt) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Unfold your iPhone to use both screens, then press Record.")
            }
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
