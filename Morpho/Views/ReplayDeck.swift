//
//  ReplayDeck.swift
//  Morpho
//
//  The lower screen while a take is loaded, in the style of the iOS video
//  viewer: Done to return to the camera, the take's date and time up top,
//  the video on black, a play/pause scrubber, and Share · Save · Delete
//  along the bottom. Swipe sideways to move between takes.
//

import AVFoundation
import SwiftUI

struct ReplayDeck: View {
    @Environment(SessionModel.self) private var session
    @Environment(MorphoEngine.self) private var engine

    @State private var confirmingDelete = false
    @State private var savingToPhotos = false

    private var replay: ReplayController { engine.replay }

    var body: some View {
        ZStack {
            Color.black

            if let clip = replay.clip {
                VStack(spacing: 0) {
                    topBar(for: clip)

                    ReplayPlayerView(player: replay.player, gravity: .resizeAspect)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { replay.togglePlayback() }
                        .gesture(swipeGesture(for: clip))
                        .accessibilityLabel("Video")
                        .accessibilityHint("Tap to play or pause, swipe to change takes")

                    scrubber
                    toolbar(for: clip)
                }
            }
        }
        .confirmationDialog("Delete this take?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Video", role: .destructive) {
                guard let clip = replay.clip else { return }
                engine.deleteClip(clip)
                // Like Photos: move on to the next take, or fall back to the camera.
                if let next = session.reel.first { engine.enterReplay(next) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Chrome

    private func topBar(for clip: Clip) -> some View {
        ZStack {
            VStack(spacing: 1) {
                Text(clip.recordedAt, format: .dateTime.month(.wide).day())
                    .font(.subheadline.weight(.semibold))
                Text(clip.recordedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }

            HStack {
                Button("Done") {
                    engine.exitReplay()
                }
                .font(.body.weight(.semibold))
                .buttonStyle(.plain)
                .accessibilityHint("Returns to the camera")
                Spacer()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    private var scrubber: some View {
        HStack(spacing: 12) {
            Button {
                replay.togglePlayback()
            } label: {
                Image(systemName: replay.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(replay.isPlaying ? "Pause" : "Play")

            Text(timeLabel(replay.currentTime))
                .font(.caption.monospacedDigit())

            Slider(value: scrubBinding, in: 0...max(replay.duration, 0.01)) {
                Text("Scrub")
            }
            .labelsHidden()
            .tint(.white)

            Text(timeLabel(replay.duration))
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func toolbar(for clip: Clip) -> some View {
        HStack {
            ShareLink(item: clip.url) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share")

            Spacer()

            Button {
                savingToPhotos = true
                Task {
                    await engine.saveClipToPhotos(clip)
                    savingToPhotos = false
                }
            } label: {
                Image(systemName: clip.savedToPhotos ? "checkmark.circle" : "square.and.arrow.down")
            }
            .disabled(clip.savedToPhotos || savingToPhotos)
            .accessibilityLabel(clip.savedToPhotos ? "Saved to Photos" : "Save to Photos")

            Spacer()

            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Delete")
        }
        .font(.title3)
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(.horizontal, 32)
        .padding(.bottom, 8)
        .frame(height: 60)
    }

    // MARK: Behavior

    private var scrubBinding: Binding<Double> {
        Binding(
            get: { replay.currentTime },
            set: { replay.seek(to: $0) }
        )
    }

    /// Newest take is first in the Reel: swipe left for older, right for newer.
    private func swipeGesture(for clip: Clip) -> some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height),
                      let index = session.reel.firstIndex(where: { $0.id == clip.id })
                else { return }
                let target = value.translation.width < 0 ? index + 1 : index - 1
                guard session.reel.indices.contains(target) else { return }
                engine.enterReplay(session.reel[target])
            }
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
