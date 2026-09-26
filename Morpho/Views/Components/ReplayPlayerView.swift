//
//  ReplayPlayerView.swift
//  Morpho
//
//  An AVPlayerLayer host with no system chrome — the Deck holds the controls.
//

import AVFoundation
import SwiftUI
import UIKit

struct ReplayPlayerView: UIViewRepresentable {
    let player: AVPlayer
    /// Fill for the Stage, fit for the viewer page. One player can drive both layers.
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        if uiView.playerLayer.videoGravity != gravity {
            uiView.playerLayer.videoGravity = gravity
        }
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
