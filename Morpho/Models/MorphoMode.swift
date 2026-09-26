//
//  MorphoMode.swift
//  Morpho
//
//  Posture-emergent modes (spec §3). Modes are derived from what the system
//  reports — size classes and reserved regions — never from hard-coded poses.
//

import SwiftUI

enum MorphoMode: String, Equatable, Sendable {
    /// Closed device, outer display: compact quick capture.
    case scout
    /// Partially folded "laptop" pose: Stage above the fold, Deck below.
    case director
    /// Fully open and flat: full-bleed Stage with a floating Deck strip.
    case canvas
}

/// Everything the layout needs to know about the current posture, computed
/// from a `GeometryProxy` at the root of the scene.
struct FoldLayout: Equatable {
    var mode: MorphoMode
    /// The fold's division region in local coordinates, when one is reported.
    var divisionFrame: CGRect?
    /// Inner-camera occlusion regions the UI must ripple around.
    var occlusionFrames: [CGRect]

    /// Fraction of the container height where the fold line sits (Rift Slider snap target).
    func foldFraction(in size: CGSize) -> CGFloat? {
        guard let divisionFrame, size.height > 0 else { return nil }
        return divisionFrame.midY / size.height
    }

    static func compute(
        proxy: GeometryProxy,
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> FoldLayout {
        let divisions = proxy.reservedRegions(kind: .division)
        let occlusions = proxy.reservedRegions(kind: .occlusion)
        let size = proxy.size

        guard let division = divisions.first else {
            // No fold region is reported when the inner display is fully open
            // and flat, so tell the displays apart by width: the inner display
            // is regular width (Canvas); the outer display is compact (Scout).
            let mode: MorphoMode = horizontalSizeClass == .regular ? .canvas : .scout
            return FoldLayout(mode: mode, divisionFrame: nil, occlusionFrames: occlusions.map(\.frame))
        }

        // A fold that runs horizontally across the view (wider than tall) is the
        // laptop pose: Stage above, Deck below. A vertical fold means the device
        // is open like a book/flat, which is Canvas.
        let isHorizontalFold = division.frame.width >= division.frame.height
        let mode: MorphoMode = isHorizontalFold && size.height > size.width * 0.8 ? .director : .canvas

        return FoldLayout(
            mode: mode,
            divisionFrame: division.frame,
            occlusionFrames: occlusions.map(\.frame)
        )
    }
}
