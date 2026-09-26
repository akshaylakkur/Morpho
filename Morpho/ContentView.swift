//
//  ContentView.swift
//  Morpho
//
//  The posture-adaptive root (spec §3). One layout, driven only by size
//  classes and reserved regions: Scout on the outer display, Director in the
//  laptop pose (ArrangementView .overlay across the fold regions), Canvas
//  when fully open. The Unfold: Scout blooms into Director through a
//  matched-geometry transition while the Deck cascades in from the fold.
//

import SwiftUI

struct ContentView: View {
    @Environment(SessionModel.self) private var session
    @Environment(MorphoEngine.self) private var engine
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Namespace private var unfoldNamespace

    var body: some View {
        GeometryReader { proxy in
            let layout = FoldLayout.compute(proxy: proxy, horizontalSizeClass: horizontalSizeClass)

            Group {
                switch layout.mode {
                case .scout:
                    ScoutView()
                        .matchedGeometryEffect(id: UnfoldID.stage, in: unfoldNamespace)
                        .transition(.opacity)

                case .director:
                    directorArrangement
                        .transition(.opacity)

                case .canvas:
                    canvasLayout
                        .transition(.opacity)
                }
            }
            .animation(Theme.unfoldSpring, value: layout.mode)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .task {
            await engine.start()
        }
    }

    // MARK: Director Mode — the hero (spec §3)

    /// ArrangementView with the .overlay style: the Stage and the Deck occupy
    /// the device's two fold regions, laid out by the system.
    ///
    /// Note: with `.overlay`, the system places the `secondary` content in the
    /// upper fold region and the primary content in the lower one, so the Deck
    /// (controls) is passed as the primary to keep it on the bottom screen.
    private var directorArrangement: some View {
        ArrangementView {
            DeckView()
        } secondary: {
            StageView()
                .matchedGeometryEffect(id: UnfoldID.stage, in: unfoldNamespace)
        }
        .arrangementViewStyle(.overlay)
    }

    // MARK: Canvas Mode — fully open, flat

    /// Stage expands full-bleed; the Deck condenses to a floating Liquid
    /// Glass strip clear of the (inactive) fold.
    private var canvasLayout: some View {
        ZStack(alignment: .bottom) {
            StageView()
                .matchedGeometryEffect(id: UnfoldID.stage, in: unfoldNamespace)

            DeckView(condensed: true)
                .padding(.bottom, 28)
        }
    }
}

private enum UnfoldID {
    static let stage = "morpho.stage"
}
