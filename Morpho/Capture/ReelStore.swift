//
//  ReelStore.swift
//  Morpho
//
//  Persists the Reel (spec §9) in the app container: each take lives in
//  Documents/Reel as an MP4 plus a JPEG thumbnail, indexed by reel.json.
//

import AVFoundation
import Foundation
import Photos
import UIKit

enum ReelStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Reel")
    }

    private static var indexURL: URL { directory.appending(path: "reel.json") }

    static func load() -> [Clip] {
        guard let data = try? Data(contentsOf: indexURL),
              let clips = try? decoder.decode([Clip].self, from: data)
        else { return [] }
        // Drop entries whose file went missing.
        return clips.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    static func save(_ clips: [Clip]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(clips) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Move a finished recording into the Reel and describe it.
    static func ingest(recording url: URL, realmName: String?) async -> Clip? {
        let id = UUID()
        let fileName = "\(id.uuidString).mp4"
        let fileURL = directory.appending(path: fileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: fileURL)
        } catch {
            return nil
        }

        let asset = AVURLAsset(url: fileURL)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        guard duration > 0 else {
            // Nothing was ever written (Record pressed with no feed); keep the Reel clean.
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        var size = CGSize.zero
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize) {
            size = natural
        }

        return Clip(
            id: id,
            fileName: fileName,
            thumbnailFileName: await writeThumbnail(for: asset, id: id),
            recordedAt: .now,
            duration: duration,
            width: Int(size.width),
            height: Int(size.height),
            realmName: realmName
        )
    }

    static func delete(_ clip: Clip) {
        try? FileManager.default.removeItem(at: clip.url)
        if let thumbnailURL = clip.thumbnailURL {
            try? FileManager.default.removeItem(at: thumbnailURL)
        }
    }

    /// Adds the take to the Photos library (add-only access).
    static func saveToPhotos(_ clip: Clip) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: clip.url)
            }
            return true
        } catch {
            return false
        }
    }

    private static func writeThumbnail(for asset: AVAsset, id: UUID) async -> String? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        guard let result = try? await generator.image(at: .zero),
              let data = UIImage(cgImage: result.image).jpegData(compressionQuality: 0.8)
        else { return nil }
        let fileName = "\(id.uuidString).jpg"
        do {
            try data.write(to: directory.appending(path: fileName), options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
