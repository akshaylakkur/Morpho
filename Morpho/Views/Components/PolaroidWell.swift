//
//  PolaroidWell.swift
//  Morpho
//
//  The Reference Well (spec §4.2): drop a reference image for character swap /
//  style source. Shown as a floating polaroid that "develops" (blur → sharp)
//  when set (spec §7).
//

import PhotosUI
import SwiftUI

struct PolaroidWell: View {
    @Binding var imageData: Data?

    @State private var pickerItem: PhotosPickerItem?
    @State private var developing = false

    var body: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            polaroid
        }
        .buttonStyle(.plain)
        .onChange(of: pickerItem) {
            guard let pickerItem else { return }
            Task {
                if let data = try? await pickerItem.loadTransferable(type: Data.self) {
                    developing = true
                    imageData = data
                    withAnimation(.easeOut(duration: 1.1)) {
                        developing = false
                    }
                }
            }
        }
        .contextMenu {
            if imageData != nil {
                Button("Remove Reference", systemImage: "trash", role: .destructive) {
                    imageData = nil
                    pickerItem = nil
                }
            }
        }
        .accessibilityLabel(imageData == nil ? "Add reference image" : "Reference image set")
    }

    private var polaroid: some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.black.opacity(0.55))
                if let imageData, let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: developing ? 12 : 0)
                        .saturation(developing ? 0.2 : 1)
                } else {
                    Image(systemName: "photo.badge.plus")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            Text("Ref")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.black.opacity(0.65))
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(white: 0.94))
                .shadow(color: .black.opacity(0.45), radius: 5, y: 3)
        )
        .rotationEffect(.degrees(imageData == nil ? 0 : -3))
        .animation(Theme.chipSpring, value: imageData)
    }
}

#Preview(traits: .sizeThatFitsLayout) {
    @Previewable @State var data: Data?
    PolaroidWell(imageData: $data)
        .padding()
        .background(Color.black)
}
