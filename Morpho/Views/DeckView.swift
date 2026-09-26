//
//  DeckView.swift
//  Morpho
//
//  The Deck (spec §4.2): three stacked Liquid Glass shelves — Realms, Voice,
//  Rig — with the Reel and the record control along the bottom. While a take
//  is loaded, ReplayDeck takes its place (spec §9). `condensed` renders the
//  floating Canvas-mode strip instead.
//

import SwiftUI

struct DeckView: View {
    @Environment(SessionModel.self) private var session
    @Environment(MorphoEngine.self) private var engine
    @Environment(VoiceConductor.self) private var conductor

    /// Canvas Mode: collapse to a single floating strip (spec §3).
    var condensed = false

    /// Drives the cascade-in when the Deck arrives (The Unfold, spec §7).
    @State private var revealed = false

    var body: some View {
        Group {
            if condensed {
                condensedStrip
            } else if engine.replay.isActive {
                ReplayDeck()
                    .transition(.opacity)
            } else {
                fullDeck
            }
        }
        .animation(.easeInOut(duration: 0.25), value: engine.replay.isActive)
        .onAppear {
            revealed = false
            withAnimation(Theme.unfoldSpring) { revealed = true }
        }
    }

    // MARK: Full Director-mode deck

    private var fullDeck: some View {
        VStack(spacing: 10) {
            shelf(index: 0) { RealmShelf() }
            shelf(index: 1) { VoiceShelf() }
            shelf(index: 2) { RigShelf() }

            // Record cluster on the Deck's trailing edge (spec §4.2), in-flow
            // below the shelves so it can never overlap the rig controls.
            HStack(spacing: 12) {
                // The Reel (spec §9): tap a take to replay it on the Stage.
                if !session.reel.isEmpty {
                    ReelStrip(clips: session.reel, selected: nil) { clip in
                        engine.enterReplay(clip)
                    }
                    .transition(.opacity)
                }
                Spacer()
                loopcastButton
                if let exportURL = session.lastExportURL {
                    ShareLink(item: exportURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .transition(.scale.combined(with: .opacity))
                }
                RecordButton(isRecording: session.isRecording) {
                    engine.toggleRecording()
                }
            }
            .padding(.trailing, 6)
            .opacity(revealed ? 1 : 0)
            .animation(Theme.chipSpring, value: session.lastExportURL)
            .animation(Theme.chipSpring, value: session.reel.count)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
    }

    /// Deck cards cascade up from the fold line with a small stagger (spec §7).
    private func shelf(index: Int, @ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .offset(y: revealed ? 0 : -34)
            .opacity(revealed ? 1 : 0)
            .animation(
                Theme.unfoldSpring.delay(Double(index) * Theme.deckCascadeStagger),
                value: revealed
            )
    }

    /// Loopcast (spec §7): hand the judge their own transformed loop.
    private var loopcastButton: some View {
        Button {
            Task { await engine.exportLoopcast() }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: "arrow.trianglehead.2.counterclockwise.rotate.90")
                    .font(.body.weight(.semibold))
                Text("Loop")
                    .font(.system(size: 8, weight: .semibold))
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Export Loopcast")
    }

    // MARK: Condensed Canvas-mode strip

    private var condensedStrip: some View {
        HStack(spacing: 14) {
            if engine.replay.isActive {
                // Minimal transport while a take plays (spec §9).
                Button("Live", systemImage: "dot.radiowaves.left.and.right") {
                    engine.exitReplay()
                }
                .buttonStyle(.bordered)
                .tint(Theme.connectedTeal)

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

                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Realm.all) { realm in
                            RealmChip(realm: realm, isActive: session.activeRealm == realm) {
                                engine.toggleRealm(realm)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }

                IncantButton(size: 54)
            }

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

// MARK: - Shelf 1: Realms

struct RealmShelf: View {
    @Environment(SessionModel.self) private var session
    @Environment(MorphoEngine.self) private var engine

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Realm.all) { realm in
                    RealmChip(realm: realm, isActive: session.activeRealm == realm) {
                        engine.toggleRealm(realm)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Shelf 2: Voice (Incant button + Spellbook)

struct VoiceShelf: View {
    @Environment(SessionModel.self) private var session
    @Environment(MorphoEngine.self) private var engine
    @Environment(VoiceConductor.self) private var conductor

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 4) {
                IncantButton(size: 72)
                Text(micLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // The Spellbook: every incantation this session; tap to re-cast.
            VStack(alignment: .leading, spacing: 6) {
                Label("Spellbook", systemImage: "book.closed.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if session.spellbook.isEmpty {
                    Text("Speak — every incantation lands here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(session.spellbook) { incantation in
                                Button {
                                    Task { await engine.recast(incantation) }
                                } label: {
                                    HStack {
                                        Image(systemName: "sparkle")
                                            .font(.caption2)
                                            .foregroundStyle(Theme.iridescent)
                                        Text(incantation.rawSpeech)
                                            .font(.caption)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 3)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 84)
                }
            }
        }
    }

    private var micLabel: String {
        switch session.micMode {
        case .idle: "Hold · tap latches"
        case .holdToTalk: "Listening…"
        case .openMic: "Open Mic"
        }
    }
}

/// The Incant control: hold-to-talk, or tap to latch Open Mic (spec §4.2).
struct IncantButton: View {
    @Environment(SessionModel.self) private var session
    @Environment(VoiceConductor.self) private var conductor

    var size: CGFloat = 72

    @State private var holdActive = false

    var body: some View {
        ZStack {
            WaveformRing(
                amplitude: session.micAmplitude,
                isListening: session.micMode != .idle
            )
            .frame(width: size + 34, height: size + 34)

            Image(systemName: session.micMode == .openMic ? "waveform.circle.fill" : "mic.fill")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(session.micMode == .idle ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.iridescent))
                .frame(width: size, height: size)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .frame(width: size + 34, height: size + 34)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.25)
                .onEnded { _ in
                    holdActive = true
                    conductor.beginHold()
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onEnded { _ in
                    if holdActive {
                        holdActive = false
                        conductor.endHold()
                    }
                }
        )
        .onTapGesture {
            conductor.toggleOpenMic()
        }
        .accessibilityLabel("Incant")
        .accessibilityHint("Hold to talk, tap to latch open mic")
    }
}

// MARK: - Shelf 3: Rig

struct RigShelf: View {
    @Environment(SessionModel.self) private var session
    @Environment(MorphoEngine.self) private var engine

    var body: some View {
        @Bindable var session = session

        HStack(spacing: 14) {
            // Camera flip + torch + zoom.
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    rigButton(
                        symbol: "arrow.trianglehead.2.clockwise.rotate.90.camera.fill",
                        label: "Flip"
                    ) {
                        engine.flipCamera()
                    }
                    rigButton(
                        symbol: session.torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                        label: "Torch",
                        active: session.torchOn
                    ) {
                        session.torchOn.toggle()
                    }
                }
                zoomRocker
            }

            Divider().frame(height: 56)

            // Decart parameters as tactile toggles (spec §4.2).
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $session.selfAnchor) {
                    Label("Anchor", systemImage: "scope")
                        .font(.caption.weight(.medium))
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)

                Toggle(isOn: $session.enhance) {
                    Label("Enhance", systemImage: "sparkles")
                        .font(.caption.weight(.medium))
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
            }

            seedDial

            Spacer(minLength: 0)

            PolaroidWell(imageData: $session.referenceImageData)
        }
    }

    private func rigButton(symbol: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.body)
                Text(label)
                    .font(.system(size: 9))
            }
            .frame(width: 44, height: 40)
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? AnyShapeStyle(Theme.iridescent) : AnyShapeStyle(.white.opacity(0.85)))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
    }

    private var zoomRocker: some View {
        @Bindable var session = session
        return HStack(spacing: 6) {
            Image(systemName: "minus.magnifyingglass").font(.caption2)
            Slider(value: $session.zoom, in: 1...3)
                .frame(width: 68)
            Image(systemName: "plus.magnifyingglass").font(.caption2)
        }
        .foregroundStyle(.secondary)
    }

    /// Seed dial, lockable for reproducible looks (spec §4.2).
    private var seedDial: some View {
        @Bindable var session = session
        return VStack(spacing: 4) {
            Button {
                session.seedLocked.toggle()
            } label: {
                Image(systemName: session.seedLocked ? "lock.fill" : "lock.open")
                    .font(.body)
                    .foregroundStyle(session.seedLocked ? AnyShapeStyle(Theme.iridescent) : AnyShapeStyle(.secondary))
                    .frame(width: 40, height: 34)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))

            Text("Seed \(String(session.seed).prefix(5))…")
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .contextMenu {
                    Button("Reroll Seed", systemImage: "dice") {
                        session.seedLocked = false
                        session.rerollSeedIfUnlocked()
                    }
                }
        }
        .accessibilityLabel(session.seedLocked ? "Seed locked" : "Seed unlocked")
    }
}
