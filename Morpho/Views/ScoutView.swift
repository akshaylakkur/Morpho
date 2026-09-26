//
//  ScoutView.swift
//  Morpho
//
//  Scout Mode (spec §4.3): compact quick-capture on the outer display.
//  System vertical bars carry symbol+title toolbar items; the viewfinder
//  extends beneath them via backgroundExtensionEffect(). Three Realm chips
//  and the Incant button stay prominent.
//

import SwiftUI

struct ScoutView: View {
    @Environment(SessionModel.self) private var session
    @Environment(MorphoEngine.self) private var engine
    @Environment(VoiceConductor.self) private var conductor

    /// The hero chips available without unfolding.
    private var scoutRealms: [Realm] {
        Array(Realm.all.prefix(3))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Hero viewfinder extends under the system vertical bars.
                StageView(compact: true)
                    .backgroundExtensionEffect()

                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        ForEach(scoutRealms) { realm in
                            RealmChip(realm: realm, isActive: session.activeRealm == realm) {
                                engine.toggleRealm(realm)
                            }
                        }
                        Spacer()
                        IncantButton(size: 52)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
                }
            }
            .ignoresSafeArea(edges: .vertical)
            .toolbar {
                // Record migrates into the system vertical bar as a proper
                // toolbar item: symbol + title, pinned so it never overflows.
                ToolbarItem(placement: .topBarPinnedTrailing) {
                    Button {
                        engine.toggleRecording()
                    } label: {
                        Label(
                            session.isRecording ? "Stop" : "Record",
                            systemImage: session.isRecording ? "stop.circle.fill" : "record.circle"
                        )
                    }
                    .tint(session.isRecording ? .red : nil)
                }

                ToolbarItemGroup {
                    Button {
                        engine.flipCamera()
                    } label: {
                        Label("Flip Camera", systemImage: "arrow.trianglehead.2.clockwise.rotate.90.camera.fill")
                    }
                }
                .visibilityPriority(.high)

                // Secondary controls live in the system overflow menu.
                ToolbarOverflowMenu {
                    Button {
                        Task { await engine.exportLoopcast() }
                    } label: {
                        Label("Loopcast", systemImage: "arrow.trianglehead.2.counterclockwise.rotate.90")
                    }
                    Button {
                        _ = engine.captureStill()
                    } label: {
                        Label("Capture Still", systemImage: "camera.shutter.button")
                    }
                    if session.activeRealm != nil || session.lastCast != nil {
                        Button {
                            engine.clearRealm()
                        } label: {
                            Label("Clear Realm", systemImage: "arrow.uturn.backward")
                        }
                    }
                    sourceMenu
                }
            }
        }
    }

    @ViewBuilder
    private var sourceMenu: some View {
        Picker("Source", selection: sourceBinding) {
            ForEach(engine.availableSources(), id: \.self) { kind in
                Label(kind.displayName, systemImage: kind.symbol)
                    .tag(kind)
            }
        }
    }

    private var sourceBinding: Binding<VideoSourceKind> {
        Binding(
            get: { session.videoSource },
            set: { engine.selectSource($0) }
        )
    }
}
