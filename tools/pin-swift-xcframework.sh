#!/usr/bin/env bash

# Rewrites the root Package.swift to a binaryTarget pinned to a release's
# prebuilt XCFramework, so a SwiftPM consumer imports Gosslens with no Zig. The
# release job runs it once the XCFramework checksum is known, as
# pin-swift-xcframework.sh <tag> <checksum>. Local dev keeps the source target.
set -euo pipefail

tag="${1:?usage: pin-swift-xcframework.sh <tag> <checksum>}"
checksum="${2:?usage: pin-swift-xcframework.sh <tag> <checksum>}"
repo="${GITHUB_REPOSITORY:-myzonerocks/gosslens}"
server="${GITHUB_SERVER_URL:-https://github.com}"
url="${server}/${repo}/releases/download/${tag}/GosslensKit.xcframework.zip"

cat > Package.swift <<EOF
// swift-tools-version:6.3
import Foundation
import PackageDescription

// The manifest a consumer resolves: a git-URL dependency reads the root
// manifest and cannot point at a subdirectory. The engine arrives as the
// XCFramework attached to each release, so there is no Zig and no build step.
// A checkout that has built its own (tools/build-xcframework.sh, into zig-out/)
// resolves that one instead, so a sibling checkout builds from source and a
// bare dependency takes the release, with no setting anywhere.
// Regenerated per release; sdk/swift/Package.swift builds from source instead.
let localKit = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("zig-out/GosslensKit.xcframework").path
let kit: Target = FileManager.default.fileExists(atPath: localKit)
    ? .binaryTarget(name: "GosslensKit", path: "zig-out/GosslensKit.xcframework")
    : .binaryTarget(
        name: "GosslensKit",
        url: "${url}",
        checksum: "${checksum}"
    )
let package = Package(
    name: "Gosslens",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Gosslens", targets: ["Gosslens"]),
        // The C surface on its own, for an app that reaches the engine's C API directly.
        .library(name: "GosslensKit", targets: ["GosslensKit"]),
    ],
    targets: [
        kit,
        .target(
            name: "Gosslens",
            dependencies: ["GosslensKit"],
            path: "sdk/swift/Sources/Gosslens",
            // The system frameworks and libraries the engine's static archives reach, carried
            // to every client so nothing is linked by hand.
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreML"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("VideoToolbox"),
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
EOF

echo "pinned Package.swift to ${tag}"
echo "  url=${url}"
echo "  checksum=${checksum}"
