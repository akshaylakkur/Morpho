# Decart Lucy 2.5 realtime — verified reference for Morpho

Read from docs.platform.decart.ai and the `decart-ios` SDK source at tag
**v0.7.1** on 2026-09-25. Where docs and source disagree, source wins and is
noted. Anything marked UNVERIFIED could not be confirmed.

## 1. Models

| Swift case | Wire name | Notes |
|---|---|---|
| `.lucy2_5` | `lucy-2.5` | **Use this.** 1280×720, 30 fps, reference images supported, `speed: .fast` supported. |
| `.lucy2_1` | `lucy-2.1` | Previous generation. |
| `.lucyVton3_5` | `lucy-vton-3.5` | Virtual try-on; the right tool for character-identity preservation. |
| `.lucyRestyle2` | `lucy-restyle-2` | Cheaper restyle model. |
| `.lucyLatest` | `lucy-latest` | Alias for 2.5 on the server, but the SDK's `ModelDefinition` for it still carries stale 1088×624 dimensions. Don't use. |

`Models.realtime(.lucy2_5)` → `ModelDefinition(name: "lucy-2.5", urlPath: "/v1/stream", fps: 30, width: 1280, height: 720, hasReferenceImage: true, supportedSpeeds: [.fast])`.

- Input: 1280×720 at 30 fps, landscape 16:9 **or** portrait 9:16 (for portrait, swap the dimensions when building the capture options: `Dimensions(width: Int32(model.height), height: Int32(model.width))`).
- Optional `resolution: .p1080` (`Resolution` enum `.p720` / `.p1080`).
- Transport is WebRTC via LiveKit. Bandwidth 1.3–2.4 Mbps each way at 30 fps; provision 4 Mbps per direction; RTT ≤ 150 ms is "good". Hosts: `api.decart.ai`, `api3.decart.ai` (WSS signaling), `lk.decart.ai`, `*.lkc.decart.ai`; UDP 7882 media, UDP 3478 TURN.
- Latency: no numeric claim anywhere in the docs.
- Prompt enhancement and self-anchoring default **on** at the API; the Swift SDK's `enrich` defaults **off** (see §2). Self-anchoring is not exposed in the Swift SDK at all (JS/Python `queryParams` only).

## 2. Swift SDK surface (v0.7.1, from source)

**Package**: `https://github.com/decartai/decart-ios.git`, `from: "0.7.1"`. Platforms iOS 17+. Depends on `livekit/client-sdk-swift` ≥ 2.5 (resolves 2.14.1) and `shareup/websocket-apple`. LiveKit is **not re-exported**: the app must `@preconcurrency import LiveKit` for `LocalVideoTrack`, `CameraCaptureOptions`, `Dimensions`, `VideoTrack`, `CameraCapturer`. A real device is required for the SDK's own camera path (no simulator camera).

**Client**
- `DecartConfiguration(baseURL: String = "https://api.decart.ai", apiKey: String)` — `fatalError`s on an empty key or bad URL. An ephemeral token is passed as `apiKey`; there is no separate token type.
- `DecartClient(decartConfiguration:)` (struct, Sendable).
- `client.createRealtimeManager(options: RealtimeConfiguration) throws -> DecartRealtimeManager`. Builds `wss://api.decart.ai/v1/stream?api_key=…&model=…[&resolution=…][&speed=fast]` **once**; the key is baked into that URL and re-dialed verbatim on every auto-reconnect.
- `@MainActor client.createLocalCameraStream(model:position: = .front, mirror: MirrorMode = .auto, debugQuality: = false) -> RealtimeMediaStream` — convenience camera factory.
- `client.checkConnectivity(options:) async -> ConnectivityReport`.

**Configuration**
- `RealtimeConfiguration(model: ModelDefinition, initialPrompt: DecartPrompt = .init(text: ""), resolution: Resolution? = nil, speed: Speed? = nil, connection: ConnectionConfig = .init(), media: MediaConfig = .init(), observability: ObservabilityConfig = .init(), debugQuality: Bool = false)`.
- `ConnectionConfig(connectionTimeout: 15, reconnectAttempts: 10, bundleInitialStateInJoin: true)`.
- `VideoConfig(maxBitrate: 3_500_000, maxFramerate: 30, preferredCodec: "h264", simulcast: true)`.
- `Speed` has one case, `.fast` (2× billing, US only, lucy-2.5 and vton-3.5).
- No `mirror`, `seed`, or `selfAnchor` options exist in the Swift SDK.

**Prompt**
- `DecartPrompt(text: String, referenceImageData: Data? = nil, enrich: Bool = false)` — all three are `public let` (immutable; set them in the initializer).
- `enrich` maps to the wire field `enhance_prompt`. Pass `session.enhance` explicitly.
- For models with `hasReferenceImage == true` (lucy-2.5), **every `setPrompt` is sent as a `set_image` message** carrying `prompt`, `image_data` (base64, may be nil) and `enhance_prompt`. Semantics are atomic-replace: omitting the image clears it server-side, so always resend the reference image with each prompt. Non-image models send a plain `prompt` message.

**Media**
- `RealtimeMediaStream(videoTrack: VideoTrack? = nil, audioTrack: AudioTrack? = nil, id: StreamId)`; `StreamId` is `.localStream` / `.remoteStream`.
- Camera track (LiveKit): `LocalVideoTrack.createCameraTrack(name: String? = nil, options: CameraCaptureOptions? = nil, reportStatistics: Bool = false, processor: VideoProcessor? = nil)`. The zero-arg overload defaults to position `.unspecified`, 1280×720, 30 fps, no processor. The documented setup is `CameraCaptureOptions(position: .front, dimensions: Dimensions(width: Int32(model.width), height: Int32(model.height)), fps: model.fps)` plus `MirroringVideoProcessor(mode: .auto, cameraPosition: .front)` as the processor.
- `MirrorMode { .off, .auto, .on }`; `MirroringVideoProcessor(mode:cameraPosition:)` with settable `mode` / `cameraPosition`.
- Camera switch: `(localVideoTrack.capturer as? CameraCapturer)?.switchCameraPosition()`, then update the processor's `cameraPosition`.
- Rendering (SwiftUI): `RTCMLVideoViewWrapper(track: VideoTrack?, mirror: Bool = false, layoutMode: VideoView.LayoutMode = .fit)`.
- Cleanup: `try? await videoTrack.stop(); await manager.disconnect()`.

**Manager** — `DecartRealtimeManager` (final class, `@unchecked Sendable`, not an actor)
- `connect(localStream:) async throws -> RealtimeMediaStream` (the remote stream; hold its `videoTrack` and render it).
- `disconnect() async`.
- `setPrompt(_ prompt: DecartPrompt) async throws` — suspends until the server acks (15 s prompt / 30 s image timeout). A newer call fails the pending one with `serverError("superseded")`.
- `waitForConnection(timeout:)`, `getConnectionQuality() -> ConnectionQualityReport?`, `getGlassToGlass()`, `isPathRelayed()`.
- Streams (all `bufferingNewest(1)`, yield on arbitrary executors — hop to `@MainActor`): `events: AsyncStream<DecartRealtimeState>`, `remoteStreamUpdates: AsyncStream<RealtimeMediaStream>` (a new stream after every successful auto-reconnect; **rebind the rendered track**), `connectionQualityUpdates`.
- `DecartRealtimeState { connectionState, serviceStatus, queuePosition, queueSize, generationTick: Double?, sessionId }`.
- `DecartRealtimeConnectionState`: `.connecting, .connected, .generating, .reconnecting, .disconnected, .idle, .error`, plus `isConnected` (connected or generating) and `isInSession`.
- Reconnect: manager-level max 5 attempts, delay `min(2^n, 10)` s. Not triggered by user `disconnect()` or permanent errors (message contains 401/403/unauthorized/invalid api key/session expired). Exhaustion → `.error`.
- `DecartError` (`errorCode` string): `.invalidAPIKey, .invalidBaseURL(String?), .webRTCError(String), .processingError, .invalidInput, .invalidOptions, .modelNotFound, .connectionTimeout, .websocketError(String), .networkError(Error), .serverError(String), .queueError`.

Doc errata: the Swift page writes `Models.realtime(.lucy-restyle-2)` (invalid Swift) and mentions `.lucy_v2v_14b_rt` (absent in v0.7.1). Trust the enum names above.

## 3. Auth: ephemeral client tokens

- Backend mints: `POST https://api.decart.ai/v1/client/tokens` with header `x-api-key: <permanent dct_… key>`. JSON body, all optional: `expiresIn` (seconds, 1–3600, **default 60**), `allowedModels` (string[], max 20), `allowedOrigins` (browser only), `constraints: { "realtime": { "maxSessionDuration": <sec, min 10> } }`, `metadata`.
- Response 200: `{ "apiKey": string, "expiresAt": string(timestamp), "permissions"?, "constraints"? }`. 401 bad key; 403 "Cannot create client token from a client token"; 422 validation.
- Expiry blocks **new** connections but does not end active sessions; `maxSessionDuration` caps a session regardless. Tokens are signed for offline verification. Don't persist tokens; mint on demand.
- The Swift SDK has no minting API; put the returned `apiKey` into `DecartConfiguration(apiKey:)`.
- Because the key is embedded in the signaling URL at manager creation, an auto-reconnect after expiry fails permanently (`.error`). Mint with `expiresIn` at least the expected session length, or handle `.error` by re-minting and rebuilding the manager.
- Concurrency: `GET /v1/realtime/quota` (`x-api-key`) → `{ limit, active, remaining }` (null = unlimited). Rejection is WebSocket close 1013 "Concurrent session limit reached". Poll ≤ 1/s.

## 4. Prompting rules for Lucy 2.5

- Length: about **750 characters** (~120 words). Exceeding returns a server error stating how many characters fit. Applies with or without enhancement.
- Structure: what changes · where it's anchored (visible details, never frame position) · how it interacts (physics, tracking, lighting) · what stays the same. One edit per prompt. Concrete nouns, no pronouns, no filler adjectives ("realistic", "seamless").
- Never send negative instructions ("Don't add a hat"). Rewrite as outcomes; don't merely prefix a keep-clause.
- Keep enhancement on (`enrich: true`).
- The eight templates on the model page:
  - Character swap: `Substitute the character in the video with <description>.`
  - Add: `Add <object> to <where>.`
  - Replace: `Change <object> with <replacement>.`
  - Remove: `Remove <object> from the scene.` (name shadows explicitly)
  - Change attribute: `Change <object> to <new attribute>.`
  - Background: `Change the background to <scene>.`
  - Style: `Change the style of the video to <style>.`
  - VFX: `Add <effect> to <location>.`
  - The prompting guide also uses "Replace the character in the video with … from the reference image."
- Reference images: JPEG/PNG/WebP, ≥ 512×512, sharp at ~1280 px on the long side, < 5 MB, **pad** to 16:9 / 9:16 rather than crop. Never send an empty prompt with an image: name the item "from the reference image" and say what to keep. Pass the prompt and image in `initialPrompt` so the first frame is already transformed. For identity preservation use VTON, not prompts.

## 5. Billing and limits

- Per second: lucy-2.5 $0.02/s standard, $0.04/s fast; vton-3.5 the same; restyle-2 $0.01/s. Usage arrives as `generationTick` events.
- No documented rate limits or session cap beyond the token's `maxSessionDuration`. Fast mode needs SDK ≥ 0.7.1.

## 6. Known gaps in Morpho's live path (fix when the package is added)

`DecartLive.swift` is inside `#if canImport(DecartSDK)` and the package has never been added, so none of this has been compiled.

| Where | Problem | Fix |
|---|---|---|
| DecartLive.swift imports | `LocalVideoTrack` is LiveKit's | add `@preconcurrency import LiveKit` |
| `DecartClient(configuration:)` | wrong label | `DecartClient(decartConfiguration:)` |
| `Models.realtime(.lucy_2_5)` | no such case | `.lucy2_5` |
| `initialPrompt: session.activeRealm.map { … }` | passes an optional; omits `enrich` | `… ?? DecartPrompt(text: "")`, pass `enrich: session.enhance` |
| `LocalVideoTrack.createCameraTrack()` | position unspecified, landscape, no mirroring | `CameraCaptureOptions(position:dimensions:fps:)` + `MirroringVideoProcessor(mode: .auto, cameraPosition: .front)` |
| `_ = try await manager.connect(...)` and `for await _ in remoteStreamUpdates` | remote stream discarded; nothing renders the remote `videoTrack` | keep the returned stream, expose the track on `MorphoEngine`, render with `RTCMLVideoViewWrapper` in `StageView`, rebind on each `remoteStreamUpdates` value |
| `applyLiveState` from stream tasks | mutates `session` off the main actor | hop to `@MainActor` |
| `prompt.enrich = session.enhance` | `enrich` is `let` | pass in the initializer |
| `context.manager?.setPrompt(prompt)` | method is `async throws`; result ignored | `try await`, handle ack timeout / "superseded" / websocket errors |
| state switch | drops `.generating`, `.idle`, `.error` | map all seven cases onto `ConnectionPhase` |
| teardown | never stops the track or disconnects | `videoTrack.stop()`, `manager.disconnect()` on stop |
| TokenService payload | expects `{ token, expires_in }` | Decart returns `{ apiKey, expiresAt }`; accept that (or have the edge function reshape) and parse `expiresAt` |
| TokenService fallback TTL 3300 s | Decart's default is **60 s** | mint with explicit `expiresIn` ≥ session length and `allowedModels: ["lucy-2.5"]`; derive cache expiry from `expiresAt` |
| `LucyPromptSpec.sanitized()` | leaves the prohibition in place, only prefixes a keep-clause | strip or rewrite negative phrasing |
| `Alchemist` templates | `style` and `vfx` don't match the model page; no awareness of an attached reference image | align templates; pass whether a reference image is set so the prompt says "from the reference image" |

What's already right: the 750-char / 120-word limit, the eight edit families, resending the reference image on every `setPrompt`, and the guide's four-question structure in the Alchemist instructions.

## 7. The Morpho tether and the live path

The USB tether feeds JPEG frames into the simulator (see STAGING.md §0). The Decart SDK expects a LiveKit `VideoTrack` as the local stream; to send tethered frames live, the relay's frames would have to be pushed into a custom LiveKit `VideoCapturer` (a `BufferCapturer`-style track fed from `CVPixelBuffer`s) instead of `createCameraTrack`. On a physical Duo the SDK's own camera path applies directly.

## Sources

docs.platform.decart.ai: `/`, `/llms.txt`, `/sdks/swift-realtime`, `/sdks/swift`, `/models/realtime/lucy-2.5`, `/models/realtime/lucy-2.5-prompting`, `/models/realtime/overview`, `/models/realtime/reference-images`, `/models/realtime/streaming-best-practices`, `/getting-started/models`, `/getting-started/client-tokens`, `/api-reference/create-client-token`, `/api-reference/get-realtime-quota`, `/getting-started/pricing`, `/integrations/network-requirements`, `/resources/faq`, `/changelog`.
github.com/DecartAI/decart-ios at v0.7.1 (Package.swift, Sources/DecartSDK/*, Example app). github.com/livekit/client-sdk-swift at 2.14.1 (CameraCapturer, CameraCaptureOptions).
