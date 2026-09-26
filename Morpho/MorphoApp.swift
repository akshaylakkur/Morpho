//
//  MorphoApp.swift
//  Morpho
//
//  Composition root: one SessionModel, one MorphoEngine, one VoiceConductor,
//  injected into the environment. The launch moment is the Stage's own
//  butterfly curtain unfolding (ButterflyCurtain.swift).
//

import SwiftUI

@main
struct MorphoApp: App {
    @State private var session: SessionModel
    @State private var engine: MorphoEngine
    @State private var conductor: VoiceConductor

    init() {
        let session = SessionModel()
        let engine = MorphoEngine(session: session)
        self.session = session
        self.engine = engine
        self.conductor = VoiceConductor(engine: engine)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
                .environment(engine)
                .environment(conductor)
        }
    }
}
