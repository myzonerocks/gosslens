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
        url: "https://github.com/myzonerocks/gosslens/releases/download/v0.12.0-alpha.3/GosslensKit.xcframework.zip",
        checksum: "e86e32eb3a33ba8a167a320e6bcc493cb0917dfc1a506e6334f814e78008d911"
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
