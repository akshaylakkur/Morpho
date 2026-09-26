//
//  DeckView.swift
//  Morpho
//
//  The lower screen, in the style of the iOS Camera app: a live duplicate
//  of the Stage fills the screen as the viewfinder, with the most recent
//  take floating at the bottom-left and Record at the bottom-right over
//  the feed. Press and hold an outlined object, or drag a box around one,
//  and say what to change: the viewfinder holds that frame while you speak
//  (click-and-augment). While a take is loaded, ReplayDeck takes its place.
//  `condensed` renders the floating Canvas-mode strip instead.
//

import SwiftUI

struct DeckView: View {
    @Environment(SessionModel.self) private var session
    @Environment(MorphoEngine.self) private var engine

    /// Canvas Mode: collapse to a single floating strip (spec §3).
    var condensed = false

    var body: some View {
        Group {
            if condensed {
                condensedStrip
            } else if engine.replay.isActive {
                ReplayDeck()
                    .transition(.opacity)
            } else {
                cameraController
            }
        }
        .animation(.easeInOut(duration: 0.25), value: engine.replay.isActive)
    }

    // MARK: Camera-style controller

    private var cameraController: some View {
        ZStack(alignment: .bottom) {
            // The viewfinder is the very same Stage the upper screen shows,
            // butterfly, reveal, and all. It fills the entire lower screen;
            // the controls float on top of the feed.
            StageView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Autodetection: segmented regions and their names ride the feed.
            // This layer belongs to the controller alone; the Stage above
            // stays untouched. While a target is locked, the frame it was
            // taken from and the regions on it hold still together.
            if session.stagePhase == .live {
                let segmentation = engine.heldSegmentation ?? engine.sceneSegmenter.current

                if let held = engine.heldFrame {
                    HeldFrameView(frame: held, zoom: session.zoom)
                        .transition(.opacity)
                }

                DetectionOverlay(
                    segmentation: segmentation,
                    zoom: session.zoom,
                    augmentedRegions: engine.augmentationsByRegion(),
                    lockedRegionID: session.targeting.target?.regionID
                )
                .transition(.opacity)

                if engine.sceneSegmenter.isUnavailable {
                    detectionUnavailableChip
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 14)
                        .transition(.opacity)
                }

                AugmentTargetingLayer(segmentation: segmentation, zoom: session.zoom)
                    .transition(.opacity)
            }

            controlBar
        }
        .background(Color.black)
        .animation(.easeOut(duration: 0.2), value: engine.heldFrame == nil)
        .accessibilityElement(children: .contain)
        .task {
            // Analyze the untouched camera frame (the source every augmentation
            // starts from), and only while the viewfinder is actually live.
            await engine.sceneSegmenter.run {
                session.stagePhase == .live ? engine.originalFrame : nil
            }
        }
    }

    /// Shown when on-device Vision can't run here (no inference backend, as
    /// in the Duo simulator) so an empty layer doesn't read as a bug.
    private var detectionUnavailableChip: some View {
        Label("Detection unavailable here · drag a box to select", systemImage: "eye.slash")
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.45), in: .capsule)
            .allowsHitTesting(false)
    }

    private var controlBar: some View {
        HStack(alignment: .center) {
            RecentTakeButton(clip: session.reel.first) {
                if let clip = session.reel.first { engine.enterReplay(clip) }
            }
            Spacer()
            RecordButton(isRecording: session.isRecording) {
                engine.toggleRecording()
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    // MARK: Condensed Canvas-mode strip

    private var condensedStrip: some View {
        HStack(spacing: 16) {
            RecentTakeButton(clip: session.reel.first) {
                if let clip = session.reel.first { engine.enterReplay(clip) }
            }

            if engine.replay.isActive {
                Button("Done") {
                    engine.exitReplay()
                }
                .font(.body.weight(.semibold))
                .buttonStyle(.bordered)

                Button {
                    engine.replay.togglePlayback()
                } label: {
                    Image(systemName: engine.replay.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.bold))
                        .frame(width: 54, height: 54)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(engine.replay.isPlaying ? "Pause" : "Play")
            }

            Spacer()

            RecordButton(isRecording: session.isRecording) {
                engine.toggleRecording()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 20)
    }
}
