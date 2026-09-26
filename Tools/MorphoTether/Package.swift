// swift-tools-version: 5.9
//
//  MorphoTether — relays a USB-attached iPhone's display into the iPhone Duo
//  simulator over loopback. See STAGING.md §4.
//

import PackageDescription

let package = Package(
    name: "MorphoTether",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MorphoTether",
            path: "Sources/MorphoTether"
        ),
    ]
)
