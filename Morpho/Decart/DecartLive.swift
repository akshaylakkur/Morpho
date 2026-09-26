//
//  DecartLive.swift
//  Morpho
//
//  The real Lucy 2.5 Realtime path. This entire file is inert until the
//  DecartSDK Swift package (https://github.com/DecartAI/decart-ios) is added
//  to the project — at which point MorphoEngine.start() automatically prefers
//  it whenever credentials are configured (see Credentials.swift).
//
//  Wiring per docs.platform.decart.ai/sdks/swift-realtime:
//    client.createRealtimeManager(options: RealtimeConfiguration(model:…))
//    manager.connect(localStream:) → remote RealtimeMediaStream
//    manager.setPrompt(DecartPrompt(text:…)) mid-session
//    manager.events / manager.remoteStreamUpdates for state + reconnect rebinds
//

#if canImport(DecartSDK)
import DecartSDK
import Foundation

/// Strong references for the live session, hung off MorphoEngine.liveContext.
final class DecartLiveContext {
    var client: DecartClient?
    var manager: DecartRealtimeManager?
    var localTrack: AnyObject?
    var eventTask: Task<Void, Never>?
    var streamTask: Task<Void, Never>?
}

extension MorphoEngine {
    /// Returns true when a live Lucy session is up; MorphoEngine then renders
    /// the remote track instead of the local simulation.
    func connectLive() async -> Bool {
        do {
            let token = try await tokenService.currentToken()
            let context = DecartLiveContext()

            let client = DecartClient(configuration: DecartConfiguration(apiKey: token))
            context.client = client

            let manager = try client.createRealtimeManager(
                options: RealtimeConfiguration(
                    model: Models.realtime(.lucy_2_5),
                    initialPrompt: session.activeRealm.map { DecartPrompt(text: $0.prompt) }
                )
            )
            context.manager = manager

            // Local capture track (LiveKit camera track on device; the Tether
            // subscription replaces this when videoSource == .tether).
            let videoTrack = LocalVideoTrack.createCameraTrack()
            context.localTrack = videoTrack
            let localStream = RealtimeMediaStream(videoTrack: videoTrack, id: .localStream)
            _ = try await manager.connect(localStream: localStream)

            // Mirror connection state into the session model.
            context.eventTask = Task { [weak self] in
                for await state in manager.events {
                    guard let self else { return }
                    self.applyLiveState(state)
                }
            }
            context.streamTask = Task { [weak self] in
                for await _ in manager.remoteStreamUpdates {
                    // Rebind the rendered track after auto-reconnects.
                    self?.session.connection = .connected
                }
            }

            liveContext = context
            return true
        } catch {
            liveContext = nil
            return false
        }
    }

    func setLivePrompt(_ spec: LucyPromptSpec) async {
        guard let context = liveContext as? DecartLiveContext else { return }
        var prompt = DecartPrompt(text: spec.prompt)
        if let referenceData = session.referenceImageData {
            prompt = DecartPrompt(text: spec.prompt, referenceImageData: referenceData)
        }
        prompt.enrich = session.enhance
        context.manager?.setPrompt(prompt)
    }

    private func applyLiveState(_ state: DecartRealtimeState) {
        // Map SDK states onto the connection orb's phases.
        switch state.connectionState {
        case .connected: session.connection = .connected
        case .connecting: session.connection = .connecting
        case .reconnecting: session.connection = .reconnecting
        case .disconnected: session.connection = .disconnected
        @unknown default: break
        }
    }
}
#endif
