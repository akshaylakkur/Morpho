//
//  Clip.swift
//  Morpho
//
//  A recorded take in the Reel (spec §9): the MP4 on disk plus what the
//  Deck needs to show it without opening the file.
//

import Foundation

struct Clip: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var fileName: String
    var thumbnailFileName: String?
    var recordedAt: Date
    var duration: TimeInterval
    var width: Int
    var height: Int
    /// The Realm that was active when the take started, for the label.
    var realmName: String?
    var savedToPhotos = false

    var url: URL { ReelStore.directory.appending(path: fileName) }

    var thumbnailURL: URL? {
        thumbnailFileName.map { ReelStore.directory.appending(path: $0) }
    }

    var durationLabel: String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
