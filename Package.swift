// swift-tools-version: 5.9
//
// Standalone test harness for the Ping Warden core logic.
//
// The library target uses an explicit `path:` so the same Swift sources back
// both the Xcode app build (via the project's filesystem-synchronized group)
// and `swift test`. The Xcode app target remains the authoritative product;
// this package exists solely so `swift test` can drive XCTest against the
// Foundation-only helpers under `PingWarden/PingWarden/Core/`.
//
// Run `swift test` from the repo root to execute the suite. SourceKit and
// IDE indexers also pick this up, eliminating the "Cannot find type" noise
// that the previous shell-script-only runner produced when files were
// inspected in isolation.

import PackageDescription

let package = Package(
    name: "PingWardenCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PingWardenCore", targets: ["PingWardenCore"])
    ],
    targets: [
        .target(
            name: "PingWardenCore",
            path: "PingWarden/PingWarden/Core"
        ),
        .testTarget(
            name: "PingWardenCoreTests",
            dependencies: ["PingWardenCore"],
            path: "Tests/PingWardenCoreTests"
        )
    ]
)
