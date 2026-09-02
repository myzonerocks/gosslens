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
import PackageDescription

// The manifest a consumer resolves: a git-URL dependency reads the root
// manifest and cannot point at a subdirectory. The engine arrives as the
// XCFramework attached to each release, so there is no Zig and no build step.
// Regenerated per release; sdk/swift/Package.swift builds from source instead.
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
            dependencies: ["GosslensKit"],
            path: "sdk/swift/Sources/Gosslens"
        ),
    ],
    swiftLanguageModes: [.v6]
)
EOF

echo "pinned Package.swift to ${tag}"
echo "  url=${url}"
echo "  checksum=${checksum}"
