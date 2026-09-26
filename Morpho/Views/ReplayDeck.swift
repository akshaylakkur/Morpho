//
//  ReplayDeck.swift
//  Morpho
//
//  The Deck while a take is loaded (spec §9): what's playing, transport,
//  and what to do with it — Share, Save to Photos, Delete — plus the Reel
//  to jump between takes and a Live button back to the feed.
//

import SwiftUI

struct ReplayDeck: View {
    @Environment(SessionModel.self) private var session
    @Environment(MorphoEngine.self) private var engine

    @State private var confirmingDelete = false
    @State private var savingToPhotos = false

    private var replay: ReplayController { engine.replay }

    var body: some View {
        VStack(spacing: 10) {
            if let clip = replay.clip {
                shelf { header(for: clip) }
                shelf { transport }
                shelf { actions(for: clip) }
            }

            HStack(spacing: 12) {
                ReelStrip(clips: session.reel, selected: replay.clip) { clip in
                    engine.enterReplay(clip)
                }
                Spacer()
                RecordButton(isRecording: session.isRecording) {
                    engine.toggleRecording()
                }
            }
            .padding(.trailing, 6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .confirmationDialog("Delete this take?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Take", role: .destructive) {
                if let clip = replay.clip { engine.deleteClip(clip) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func shelf(@ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    // MARK: Shelves

    private func header(for clip: Clip) -> some View {
        HStack(spacing: 10) {
            Label("Replay", systemImage: "play.rectangle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.iridescent)
            Text(clip.realmName ?? "Original")
                .font(.subheadline.weight(.semibold))
            Text(clip.recordedAt, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Live", systemImage: "dot.radiowaves.left.and.right") {
                engine.exitReplay()
            }
            .buttonStyle(.bordered)
            .tint(Theme.connectedTeal)
        }
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                replay.restart()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Restart")

            Button {
                replay.togglePlayback()
            } label: {
                Image(systemName: replay.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2.weight(.bold))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(replay.isPlaying ? "Pause" : "Play")

            VStack(spacing: 2) {
                Slider(value: scrubBinding, in: 0...max(replay.duration, 0.01)) {
                    Text("Scrub")
                }
                .labelsHidden()
                .tint(Theme.connectedTeal)

                HStack {
                    Text(timeLabel(replay.currentTime))
                    Spacer()
                    Text("-" + timeLabel(max(0, replay.duration - replay.currentTime)))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var scrubBinding: Binding<Double> {
        Binding(
            get: { replay.currentTime },
            set: { replay.seek(to: $0) }
        )
    }

    private func actions(for clip: Clip) -> some View {
        HStack(spacing: 10) {
            ShareLink(item: clip.url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)

            Button {
                savingToPhotos = true
                Task {
                    await engine.saveClipToPhotos(clip)
                    savingToPhotos = false
                }
            } label: {
                Label(
                    clip.savedToPhotos ? "In Photos" : "Save to Photos",
                    systemImage: clip.savedToPhotos ? "checkmark.circle.fill" : "photo.badge.arrow.down"
                )
            }
            .buttonStyle(.bordered)
            .disabled(clip.savedToPhotos || savingToPhotos)

            Spacer()

            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
        }
        .font(.caption.weight(.medium))
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
