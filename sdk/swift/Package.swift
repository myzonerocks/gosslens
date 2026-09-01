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
            url: "https://github.com/myzonerocks/gosslens/releases/download/v0.9.0/GosslensKit.xcframework.zip",
            checksum: "d25ad5a5b80cd1066cde962709b476d2f9821a22b2fd174eabe93d758122424f"
        ),
        .target(
            name: "Gosslens",
            dependencies: ["GosslensKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
