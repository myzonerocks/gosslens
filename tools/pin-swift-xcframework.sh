#!/usr/bin/env bash

# Rewrites sdk/swift/Package.swift to a binaryTarget pinned to a release's
# prebuilt XCFramework, so a SwiftPM consumer imports Gosslens with no Zig. The
# release job runs it once the XCFramework checksum is known, as
# pin-swift-xcframework.sh <tag> <checksum>. Local dev keeps the source target.
set -euo pipefail

tag="${1:?usage: pin-swift-xcframework.sh <tag> <checksum>}"
checksum="${2:?usage: pin-swift-xcframework.sh <tag> <checksum>}"
repo="${GITHUB_REPOSITORY:-myzonerocks/gosslens}"
server="${GITHUB_SERVER_URL:-https://github.com}"
url="${server}/${repo}/releases/download/${tag}/GosslensKit.xcframework.zip"

cat > sdk/swift/Package.swift <<EOF
// swift-tools-version:6.3
import PackageDescription

// The engine ships as a prebuilt XCFramework attached to each release, so a
// consumer adds this package and imports Gosslens with no Zig and no build
// step. The XCFramework carries the merged static engine and the C ABI module.
// This file is regenerated per release by tools/pin-swift-xcframework.sh.
let package = Package(
    name: "Gosslens",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Gosslens", targets: ["Gosslens"]),
    ],
    targets: [
        .binaryTarget(
            name: "GosslensKit",
            url: "${url}",
            checksum: "${checksum}"
        ),
        .target(
            name: "Gosslens",
            dependencies: ["GosslensKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
EOF

echo "pinned sdk/swift/Package.swift to ${tag}"
echo "  url=${url}"
echo "  checksum=${checksum}"
