// swift-tools-version: 5.9
//
//  MorphoVoice — listens on the Mac's microphone, transcribes with the Mac's
//  on-device SpeechTranscriber, and streams the words into the iPhone Duo
//  simulator over loopback. See STAGING.md §0.5.
//

import PackageDescription

let package = Package(
    name: "MorphoVoice",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "MorphoVoice",
            path: "Sources/MorphoVoice"
        ),
    ]
)
