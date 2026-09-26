# Morpho — Go-Live Staging Guide

The app is **fully functional right now with zero credentials**: it runs a
simulated Lucy transformer over a synthetic (or bundled) clip, so every
feature — voice casting, Realms, the Rift Slider, recording, Loopcast — works
end-to-end on the iPhone Duo simulator. Each step below unlocks a live tier.

## 0. The Tether: the iPhone 17e's camera over USB (working today)

The demo's camera is a real iPhone on a cable. `Tools/tether.sh` builds and
launches **Morpho Tether**, a small Mac helper that opens the phone as a
Continuity Camera over USB — the phone's actual sensor feed at 1080p — and
re-serves it to the simulator. While it's open, the phone shows Apple's
"Connected to Mac" screen; nothing needs to run on the phone itself.

```sh
Tools/tether.sh                        # leave running; Ctrl-C stops it
Tools/tether.sh --list                 # what the Mac can see (camera + screen)
Tools/tether.sh --rotate 90            # frames arrive landscape; turn them portrait
Tools/tether.sh --mode screen          # stream the phone's display instead (QuickTime path)
Tools/tether.sh --snapshot /tmp/f.jpg  # save one frame to check framing
```

How it stays safe:

- **Phone → Mac is the USB cable only.** No Wi-Fi, no cloud. The phone must
  be unlocked, trusted, and on the same Apple Account with Continuity
  Camera enabled (Settings › General › AirPlay & Continuity).
- **Mac → simulator is loopback only.** The relay binds `127.0.0.1:47810`
  and is unreachable from the LAN.
- **Per-launch secret.** A 256-bit token is published with the port in
  `~/Library/Application Support/Morpho/tether.json` (mode `0600`); the app
  reads it via `SIMULATOR_HOST_HOME` and must present it before a single
  frame is sent. Wrong token → disconnected. Nothing else is written to
  disk, and that file is removed on exit.
- **Permission is attributed to "Morpho Tether"**, signed with your Apple
  Development identity, so the camera grant persists across rebuilds.

In the app, `VideoSourceKind.tether` is selectable whenever running in the
simulator. `MorphoEngine` prefers it at launch when the relay is up, and
while on the demo clip it polls every 2 s and hops over as soon as the relay
appears — so start order doesn't matter. `Decart/TetherFrameSource.swift`
holds the client and the wire format; keep it in sync with
`Tools/MorphoTether/Sources/MorphoTether/FrameServer.swift`.

Known quirks: Continuity Camera delivers landscape 16:9 frames; the Stage
scales-to-fill, so hold the phone landscape or pass `--rotate 90`. In
`--mode screen` the first frame can take ~10 s and a locked phone shows its
lock screen.

**The reveal.** The Stage opens on the Morpho butterfly (the launch moment
itself: it unfolds like the device). The first press of Record — on the
Deck or in Scout's toolbar — sends the wings off to the edges while an
iris opens onto the live feed, and recording arms at the same moment. If
no frames are arriving yet, the Stage reads "Camera Not Connected" until
the tether delivers; the recorder only opens its file on the first real
frame, so an early Record never produces a mis-sized clip. State lives in
`SessionModel.stagePhase`; the motion is `Views/Components/ButterflyCurtain.swift`.

**Feed liveness** is one simple check: has a new frame arrived in the last
1.2 s. Pause or Disconnect on the phone's "Connected to Mac" screen, a
pulled cable, or a stopped relay all look identical — frames stop. When
that happens on a live Stage the reveal runs in reverse (iris closes, wings
come home) and the butterfly rests with "Camera Not Connected" beneath it;
when frames return, an armed Stage reopens on its own. A byte-identical
repeated frame counts as no frame (that's how Continuity Camera holds its
last picture while paused).

**The lower screen (interim, Camera-app style).** The Deck is being redone
from scratch. For now it shows a live duplicate of the Stage as the
viewfinder, the newest take's thumbnail at the bottom-left, and Record at
the bottom-right — nothing else. The Realm, Voice and Rig shelves, Loopcast,
Share and the reel strip are gone from the Deck (their engine capabilities
remain and Scout on the outer display still exposes some of them).

**The Reel and replay.** Stopping Record finalizes the take and files it in
the Reel (`Documents/Reel`, MP4 + JPEG thumbnail, indexed by `reel.json`,
persisted across launches). The Stage then closes back to the resting butterfly until the next Record.
Tapping the thumbnail opens the newest take in an iOS-video-viewer-style
page on the lower screen: Done (top-left) returns to the camera, the take's
date and time sit up top, the video plays on black with a tap-to-pause and
a play/pause scrubber, and Share · Save to Photos · Delete run along the
bottom. Swipe left/right to move between takes. The Stage above plays the
same take. Files: `Models/Clip.swift`, `Capture/ReelStore.swift`,
`Capture/ReplayController.swift`, `Views/ReplayDeck.swift`,
`Views/Components/RecentTakeButton.swift`.

## 1. Add the Decart SDK package (one time, in Xcode UI)

> File ▸ Add Package Dependencies… → `https://github.com/DecartAI/decart-ios`
> → Up to Next Major from **0.7.0** → add product **DecartSDK** to the
> **Morpho** target. (LiveKit comes in transitively.)

That's it — `Decart/DecartLive.swift` is entirely wrapped in
`#if canImport(DecartSDK)` and activates automatically once the package
resolves. `MorphoEngine.start()` then prefers the live path whenever
credentials exist.

## 2. Add credentials

Create `Morpho/Secrets.plist` and add it to the **Morpho** target (it is
loaded at runtime by `Decart/Credentials.swift`; keep it out of git):

| Key | Type | Purpose | Unlocks |
|---|---|---|---|
| `TOKEN_ENDPOINT` | String | Supabase Edge Function URL that mints Decart ephemeral tokens | Live Lucy 2.5 (event-safe auth) |
| `SUPABASE_ANON_KEY` | String | Sent as `Authorization: Bearer …` to the edge function | — |
| `DECART_API_KEY` | String | Direct API key — DEV ONLY fallback, never ship | Live Lucy without the edge fn |
| `LIVEKIT_URL` | String | Reserved for a wireless tether (see §4) | — |
| `LIVEKIT_TOKEN` | String | Reserved for a wireless tether (see §4) | — |

Template:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>TOKEN_ENDPOINT</key>
    <string>https://YOUR-PROJECT.supabase.co/functions/v1/decart-token</string>
    <key>SUPABASE_ANON_KEY</key>
    <string>eyJ…</string>
</dict>
</plist>
```

The edge function is expected to return `{ "token": "…", "expires_in": 3600 }`
(see `Decart/TokenService.swift`).

## 3. Pre-event assets (all optional; graceful fallbacks exist)

| Asset | Where | Fallback today |
|---|---|---|
| `DemoClip.mp4` (well-lit, steady, single subject, 9:16) | app bundle | procedurally animated synthetic clip |
| `realm-<id>.mp4` 2-second loops ×7 (`realm-thunderstorm`, `realm-claymation`, `realm-neotokyo`, `realm-origami`, `realm-goldenhour`, `realm-underwater`, `realm-noir`) | app bundle | accent-gradient + SF Symbol chips |
| App icon (butterfly, folds along symmetry axis) | Assets.xcassets | default |
| Sounds: cast chime, shutter, unfold whoosh | bundle + small `AVAudioPlayer` calls | silent |

## 4. Wireless tether (optional, not started)

The USB tether above is the event path. `LIVEKIT_URL`/`LIVEKIT_TOKEN` in
`Credentials.swift` are reserved for a wireless variant (a `CaptureNode`
scheme on the 17e publishing to a LiveKit room) if a cable ever isn't an
option; nothing reads them today.

## Known simulator quirks (verified 2026-09-18)

- Posture switching has no public simctl command. Working private channel:
  `xcrun simctl spawn booted notifyutil -s com.apple.BackBoardServices.posture <0|1|2> -p com.apple.BackBoardServices.posture`
  (0 = closed/outer, 1 = laptop, 2 = flat). Boot the Duo simulator at
  check-in — first launch is slow (spec §13).
- ArrangementView `.overlay` places the **secondary** closure in the *upper*
  fold region — that's why `ContentView.directorArrangement` passes the Deck
  as primary.
- The flat posture (2) still reports a division region and the app scene
  never rotates to landscape in the simulator, so **Canvas Mode is only
  reachable on hardware** (vertical fold). Scout + Director are fully
  verifiable in-sim.
- Refolding to posture 0 doesn't reactivate the outer display panel in the
  simulator; relaunch the app to demo Scout again.
- FoundationModels availability in-sim is flaky (spec §13); the Alchemist
  auto-falls back to the deterministic template engine — the voice loop never
  blocks on the LLM.

## Deferred modernizations (deliberate, warnings-only)

- `Recorder.swift` uses the pre-27 `AVAssetWriterInputPixelBufferAdaptor` API
  (deprecated in 27.0 in favor of `inputPixelBufferReceiver`); it works
  correctly. Same for `AVPlayerItemVideoOutput.copyPixelBuffer` in
  `FrameSources.swift` and `installTap` in `SpeechPipeline.swift`.
- Live Activity for Scout recording (spec §4.3) needs a widget extension,
  which the Duo simulator can't run (spec §14) — pitch as roadmap.
