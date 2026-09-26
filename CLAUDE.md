# Morpho — working notes for assistants

Morpho is a realtime scene-transformation demo for iPhone Duo (iOS 27.1 SDK,
Bitrig-built, Duo simulator). Voice → Lucy 2.5 prompt → transformed feed.

## On-demand reference docs (read before touching the related area)

- `docs/ON_DEVICE_ML.md` — every on-device neural-network API available to
  the app on iOS 27 / iPhone Duo (language, vision, imaging, audio, speech,
  Core ML), with entry points, availability, simulator behavior, and fit.
- `docs/DECART_LUCY_2_5.md` — the Decart Lucy 2.5 realtime contract: Swift
  SDK surface, auth, prompting rules, and known gaps in `Decart/DecartLive.swift`.
- `STAGING.md` — how to go live (SDK package, credentials, the USB tether
  relay in `Tools/`, the Stage reveal, the Reel) and simulator quirks.

## Ground rules

- The app must stay fully functional with no credentials (simulated Lucy).
- All persistent session state lives in `SessionModel`; the engine mutates it.
- Frames are high-frequency and live on `MorphoEngine`, not the session.
- Keep `TetherFrameSource.swift` and `Tools/MorphoTether/.../FrameServer.swift`
  wire formats in sync.
- Keep `Alchemist/HostVoiceRelay.swift` and
  `Tools/MorphoVoice/.../VoiceServer.swift` wire formats in sync.
- Nothing may open a billed Lucy session implicitly: `LucyDirector` opens
  sessions only while something is cast, and only in the mode the person
  picked; Live is confirmed each time and never restored from disk. Test
  pipeline changes in Rehearsal.
