//
//  TargetingHUD.swift
//  Morpho
//
//  The click-and-augment card on the Deck, voice only: which thing is
//  locked, whether the mic is listening, and a clearly bounded transcript
//  box showing the words as they arrive — exactly what will be compiled —
//  which then holds the finished sentence while the prompt is composed.
//

import SwiftUI

struct TargetingHUD: View {
    @Environment(SessionModel.self) private var session
    @Environment(VoiceConductor.self) private var conductor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            TranscriptBox(
                caption: transcriptCaption,
                text: transcriptText,
                placeholder: placeholder,
                isFinal: isCompiling || isStaged,
                isLive: session.micMode == .targeting && session.targetingMicReady && !transcriptText.isEmpty
            )

            HStack(spacing: 10) {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Cancel", role: .cancel) {
                    conductor.cancelTargeting()
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: 440)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Augmentation")
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                WaveformRing(amplitude: session.micAmplitude, isListening: session.micMode == .targeting && session.targetingMicReady)
                    .frame(width: 44, height: 44)
                Image(systemName: headerSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(session.micMode == .targeting ? AnyShapeStyle(Theme.iridescent) : AnyShapeStyle(.white))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            if isCompiling {
                ProgressView()
                    .tint(.white)
            }
        }
        .animation(Theme.chipSpring, value: status)
    }

    // MARK: Copy

    private var isCompiling: Bool {
        if case .compiling = session.targeting { return true }
        return false
    }

    private var isStaged: Bool {
        if case .staged = session.targeting { return true }
        return false
    }

    private var title: String {
        switch session.targeting {
        case .idle: ""
        case .listening(let target), .compiling(let target, _), .staged(let target, _): target.label
        }
    }

    private var status: String {
        switch session.targeting {
        case .idle:
            ""
        case .listening:
            if session.targetingMicUnavailable {
                "Microphone unavailable · \(session.targetingMicFailureReason ?? "unknown reason")"
            } else if session.micMode != .targeting || !session.targetingMicReady {
                "Opening microphone…"
            } else {
                "Listening · pause when you're done"
            }
        case .compiling:
            "Composing the prompt"
        case .staged:
            "Staged for Lucy"
        }
    }

    private var transcriptCaption: String {
        switch session.targeting {
        case .compiling: "Casting"
        case .staged: "Prompt"
        default: "Heard"
        }
    }

    private var transcriptText: String {
        switch session.targeting {
        case .compiling(_, let speech): speech
        case .staged(_, let spec): spec.prompt
        default: session.liveTranscript
        }
    }

    private var placeholder: String {
        "Say what to change, like “make this look like a ninja”"
    }

    private var hint: String {
        switch session.targeting {
        case .listening: session.targetingMicUnavailable ? "Voice casting needs a microphone" : "Only the words in the box are used"
        case .compiling: "Bundling with the selection"
        case .staged: "Sent to Lucy once it's connected"
        case .idle: ""
        }
    }

    private var headerSymbol: String {
        switch session.targeting {
        case .compiling, .staged: "wand.and.stars"
        default: session.targetingMicUnavailable ? "mic.slash" : "mic.fill"
        }
    }
}

/// The designated transcript box: a caption, then the live words in large
/// rounded type. Its border lights up in the identity gradient while words
/// are arriving, and the words turn iridescent once they're final.
private struct TranscriptBox: View {
    let caption: String
    let text: String
    let placeholder: String
    let isFinal: Bool
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(.system(size: 9, weight: .bold))
                Text(caption.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.9)
                Spacer()
                if isLive {
                    Circle()
                        .fill(Theme.reconnectingRed)
                        .frame(width: 6, height: 6)
                    Text("LIVE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.9)
                }
            }
            .foregroundStyle(.white.opacity(0.6))

            Text(text.isEmpty ? placeholder : text)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(textStyle)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                .contentTransition(.numericText())
                .animation(Theme.chipSpring, value: text)
        }
        .padding(12)
        .background(.black.opacity(0.35), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(borderStyle, lineWidth: isLive || isFinal ? 1.5 : 1)
        }
        .animation(.easeOut(duration: 0.2), value: isLive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.isEmpty ? placeholder : "\(caption): \(text)")
    }

    private var textStyle: AnyShapeStyle {
        if text.isEmpty { return AnyShapeStyle(.white.opacity(0.4)) }
        return isFinal ? AnyShapeStyle(Theme.iridescent) : AnyShapeStyle(.white)
    }

    private var borderStyle: AnyShapeStyle {
        isLive || isFinal ? AnyShapeStyle(Theme.iridescent) : AnyShapeStyle(.white.opacity(0.15))
    }
}
