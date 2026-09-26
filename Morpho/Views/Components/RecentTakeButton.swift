//
//  RecentTakeButton.swift
//  Morpho
//
//  The Camera-app-style thumbnail at the bottom-left of the controller: the
//  newest take in the Reel, or an empty well before the first recording.
//

import SwiftUI

struct RecentTakeButton: View {
    let clip: Clip?
    let action: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.12))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(clip == nil)
        .task(id: clip?.thumbnailURL) {
            guard let url = clip?.thumbnailURL else {
                image = nil
                return
            }
            image = UIImage(contentsOfFile: url.path)
        }
        .accessibilityLabel(clip.map { "Latest take, \($0.durationLabel)" } ?? "No takes yet")
        .accessibilityHint(clip == nil ? "" : "Opens replay")
    }
}
