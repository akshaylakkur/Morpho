//
//  ScoutView.swift
//  Morpho
//
//  Scout Mode (spec §4.3): the outer display. Only the Morpho butterfly rests
//  here; recording starts on the dual screen, so Record asks to unfold. While
//  a take recorded on the dual screen is running, the outer display holds the
//  butterfly on black with "Recording in progress" and the take's timer.
//

import SwiftUI

struct ScoutView: View {
    @Environment(SessionModel.self) private var session
    @Environment(MorphoEngine.self) private var engine

    @State private var isShowingUnfoldPrompt = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black

                ButterflyCurtain(
                    phase: .curtain,
                    compact: true,
                    caption: session.isRecording ? "Recording in progress" : nil,
                    backdrop: .black
                )

                if session.isRecording, let startedAt = session.recordingStartedAt {
                    VStack {
                        Spacer()
                        SessionTimerChip(startedAt: startedAt)
                            .padding(.bottom, 24)
                    }
                    .transition(.opacity)
                }
            }
            .ignoresSafeArea()
            .animation(.smooth, value: session.isRecording)
            .toolbar {
                ToolbarItem(placement: .topBarPinnedTrailing) {
                    if session.isRecording {
                        Button("Stop", systemImage: "stop.circle.fill") {
                            engine.toggleRecording()
                        }
                        .tint(.red)
                    } else {
                        Button("Record", systemImage: "record.circle") {
                            isShowingUnfoldPrompt = true
                        }
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
}
