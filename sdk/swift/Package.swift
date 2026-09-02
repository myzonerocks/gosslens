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
            url: "https://github.com/myzonerocks/gosslens/releases/download/v0.10.1/GosslensKit.xcframework.zip",
            checksum: "364c2179187b5e0657ea923fe9d2bc158dda6c5a65597fe2928917586cd4a123"
        ),
        .target(
            name: "Gosslens",
            dependencies: ["GosslensKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
