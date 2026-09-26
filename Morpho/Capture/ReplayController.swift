//
//  ReplayController.swift
//  Morpho
//
//  Plays a Reel take on the Stage (spec §9). The Deck drives it; the Stage
//  renders `player` through ReplayPlayerView.
//

import AVFoundation
import Foundation
import Observation

@Observable
final class ReplayController {
    private(set) var clip: Clip?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    var isActive: Bool { clip != nil }

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self, time.isNumeric else { return }
            currentTime = time.seconds
        }
    }

    func load(_ clip: Clip, autoplay: Bool = true) {
        self.clip = clip
        duration = clip.duration
        currentTime = 0

        let item = AVPlayerItem(url: clip.url)
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
        }
        if autoplay { play() }
    }

    /// Refresh metadata for the loaded take (e.g. after saving to Photos).
    func update(_ clip: Clip) {
        guard self.clip?.id == clip.id else { return }
        self.clip = clip
    }

    func play() {
        if duration > 0, currentTime >= duration - 0.05 {
            player.seek(to: .zero)
            currentTime = 0
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    func restart() {
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = 0
        play()
    }

    func seek(to seconds: TimeInterval) {
        let clamped = max(0, min(seconds, duration))
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func exit() {
        pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        clip = nil
        currentTime = 0
        duration = 0
    }
}
