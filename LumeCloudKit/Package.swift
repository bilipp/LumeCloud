// swift-tools-version: 6.0
// LumeCloudKit — the Swift client for Lume Cloud: key derivation, the record
// envelope, canonical payloads, HPKE pairing, and a tiny async HTTP/WebSocket
// client. Foundation + CryptoKit only: the Lume app consumes this as a local
// package, so it must never add a dependency to the app graph.

import PackageDescription

let package = Package(
    name: "LumeCloudKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .visionOS(.v2),
    ],
    products: [
        // Automatic library type, like LumeRecorderKit: Xcode links it statically into the app.
        .library(name: "LumeCloudKit", targets: ["LumeCloudKit"]),
    ],
    targets: [
        .target(
            name: "LumeCloudKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LumeCloudKitTests",
            dependencies: ["LumeCloudKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
