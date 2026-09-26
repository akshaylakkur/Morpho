//
//  ReelStrip.swift
//  Morpho
//
//  The Reel (spec §9): every take, newest first, as tappable thumbnails.
//  Tapping one loads it for replay on the Stage.
//

import SwiftUI

struct ReelStrip: View {
    let clips: [Clip]
    let selected: Clip?
    let onSelect: (Clip) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(clips) { clip in
                    ClipThumbnail(clip: clip, isSelected: clip.id == selected?.id) {
                        onSelect(clip)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 56)
        .accessibilityLabel("Reel")
    }
}

/// One take: thumbnail with a duration badge; iridescent ring when loaded.
struct ClipThumbnail: View {
    let clip: Clip
    let isSelected: Bool
    let action: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Theme.iridescent.opacity(0.35)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            isSelected ? AnyShapeStyle(Theme.iridescent) : AnyShapeStyle(.white.opacity(0.18)),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                )

                Text(clip.durationLabel)
                    .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(3)
            }
        }
        .buttonStyle(.plain)
        .task(id: clip.thumbnailURL) {
            guard let url = clip.thumbnailURL else { return }
            image = UIImage(contentsOfFile: url.path)
        }
        .accessibilityLabel("\(clip.realmName ?? "Original") take, \(clip.durationLabel)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
