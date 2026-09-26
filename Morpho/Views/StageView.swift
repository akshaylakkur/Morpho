//
//  StageView.swift
//  Morpho
//
//  The Stage (spec §4.1): live transformed viewfinder, Rift Slider,
//  Incantation overlay, connection orb, transmutation sweep, fold shimmer,
//  and tap-to-still. Reads its own reserved regions so fold snapping adapts
//  to wherever the arrangement places it. Until the first Record it rests
//  behind the butterfly curtain, which returns whenever the feed goes quiet
//  (spec §7). A loaded Reel take plays here in place of the feed (spec §9).
//

import SwiftUI

struct StageView: View {
    @Environment(SessionModel.self) private var session
    @Environment(MorphoEngine.self) private var engine

    /// Compact chrome for Scout Mode.
    var compact = false

    @State private var stillFlash = false

    var body: some View {
        @Bindable var session = session

        GeometryReader { proxy in
            let divisions = proxy.reservedRegions(kind: .division)
            let occlusions = proxy.reservedRegions(kind: .occlusion)
            let foldFraction = divisions.first.map { $0.frame.midY / max(proxy.size.height, 1) }
            let riftAxis: Axis = divisions.first.map { $0.frame.width >= $0.frame.height } ?? false
                ? .vertical
                : .horizontal

            ZStack {
                Theme.stageBackground

                feed(in: proxy.size, foldFraction: foldFraction, axis: riftAxis)

                if session.stagePhase == .live, !engine.replay.isActive {
                    // Rift Slider: parked at 100% transformed until a judge drags it.
                    RiftSlider(
                        fraction: $session.riftFraction,
                        axis: riftAxis,
                        snapFraction: foldFraction
                    )

                    if let foldFraction {
                        FoldShimmer(foldFraction: foldFraction)
                    }
                }

                // Transmutation sweep fires from the fold outward on every cast.
                TransmutationSweep(
                    trigger: session.sweepTrigger,
                    originFraction: foldFraction ?? 0.5
                )

                // A loaded take plays here instead of the feed (spec §9).
                if engine.replay.isActive {
                    ReplayPlayerView(player: engine.replay.player)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .transition(.opacity)
                }

                // The butterfly holds the Stage until the first Record, and
                // comes back whenever the feed goes quiet (spec §7).
                if session.stagePhase != .live, !engine.replay.isActive {
                    ButterflyCurtain(phase: session.stagePhase, compact: compact, caption: curtainCaption)
                        .transition(.opacity)
                }

                chrome(occlusions: occlusions.map(\.frame), size: proxy.size)

                // Shutter flash for "stills from another world" (spec §9).
                Color.white
                    .opacity(stillFlash ? 0.85 : 0)
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.3), value: session.stagePhase)
            .animation(.easeOut(duration: 0.3), value: engine.replay.isActive)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                captureStill()
            }
        }
        .clipped()
    }

    // MARK: Feed compositing (original ↔ transformed via the rift)

    @ViewBuilder
    private func feed(in size: CGSize, foldFraction: CGFloat?, axis: Axis) -> some View {
        ZStack {
            // Nothing here reads the frames while the curtain is down, so the
            // Stage doesn't re-render 30× a second behind it.
            if session.stagePhase != .curtain {
                StageFeed(size: size, axis: axis)
            }
        }
        // Reconnects refract the stage instead of freezing it (spec §7).
        .blur(radius: session.connection == .reconnecting ? 9 : 0)
        .animation(.easeInOut(duration: 0.3), value: session.connection)
    }

    // MARK: Chrome

    private func chrome(occlusions: [CGRect], size: CGSize) -> some View {
        // Keep the orb clear of the inner camera's occlusion region (spec §3):
        // if anything occludes the top-trailing corner, slide to top-leading.
        let trailingBlocked = occlusions.contains {
            $0.intersects(CGRect(x: size.width * 0.55, y: 0, width: size.width * 0.45, height: 90))
        }

        return VStack {
            HStack {
                if trailingBlocked { orbCluster } else { Spacer() }
                Spacer()
                if !trailingBlocked { orbCluster }
            }
            .padding(.top, compact ? 8 : 14)
            .padding(.horizontal, 14)
            .animation(Theme.chipSpring, value: trailingBlocked)

            Spacer()

            IncantationOverlay(
                transcript: session.liveTranscript,
                compiled: session.compiledPreview
            )
            .padding(.bottom, compact ? 14 : 26)
        }
    }

    private var orbCluster: some View {
        HStack(spacing: 8) {
            if let clip = engine.replay.clip {
                ReplayBadge(clip: clip)
            } else {
                ConnectionOrb(phase: session.connection)
            }
            if session.isRecording, let startedAt = session.recordingStartedAt {
                SessionTimerChip(startedAt: startedAt)
            }
        }
    }

    /// Under the resting butterfly once Record has been pressed and the phone isn't sending.
    private var curtainCaption: String? {
        session.stagePhase == .curtain && session.stageArmed && !engine.feedIsLive
            ? "Camera Not Connected"
            : nil
    }

    private func captureStill() {
        guard session.stagePhase == .live, !engine.replay.isActive, engine.transformedFrame != nil else { return }
        _ = engine.captureStill()
        stillFlash = true
        withAnimation(.easeOut(duration: 0.35)) {
            stillFlash = false
        }
    }
}

/// The frames themselves, split out so only this view re-evaluates per frame.
private struct StageFeed: View {
    @Environment(SessionModel.self) private var session
    @Environment(MorphoEngine.self) private var engine

    let size: CGSize
    let axis: Axis

    var body: some View {
        ZStack {
            if let original = engine.originalFrame {
                frameImage(original)
            }
            if let transformed = engine.transformedFrame {
                frameImage(transformed)
                    .mask(alignment: axis == .vertical ? .top : .leading) {
                        Rectangle()
                            .frame(
                                width: axis == .horizontal ? session.riftFraction * size.width : nil,
                                height: axis == .vertical ? session.riftFraction * size.height : nil
                            )
                    }
            }
            // Once the curtain is up, a quiet feed says so until frames arrive.
            if !engine.feedIsLive, session.stagePhase == .live {
                cameraNotConnected
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: engine.feedIsLive)
    }

    private func frameImage(_ frame: CGImage) -> some View {
        Image(decorative: frame, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .scaleEffect(session.zoom)
            .clipped()
    }

    private var cameraNotConnected: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash")
                .font(.system(size: 42))
                .foregroundStyle(Theme.iridescent)
                .symbolEffect(.pulse)
            Text("Camera Not Connected")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
        }
        .accessibilityElement(children: .combine)
    }
}

/// Replaces the connection orb while a take is playing (spec §9).
private struct ReplayBadge: View {
    let clip: Clip

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.fill")
                .font(.caption2.weight(.bold))
            Text("Replay · \(clip.durationLabel)")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .accessibilityLabel("Replaying a \(clip.durationLabel) take")
    }
}
