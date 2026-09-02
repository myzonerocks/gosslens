// swift-tools-version:6.3
import PackageDescription

// The from-source manifest, for a fork or a local engine build: `cd sdk/swift
// && swift build` resolves this one. A consumer adding the package by URL
// resolves the repository-root manifest instead, which downloads the release
// XCFramework and needs no Zig.

// The engine links as the static archives `zig build ios` and `ios-simulator`
// install into zig-out. Naming them here means a build points
// LIBRARY_SEARCH_PATHS at that directory per slice instead of hand-copying
// the -l list out of the demo; docs/INTEGRATION-iOS.md is the guide.
let engineLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("gosslens", .when(platforms: [.iOS])),
    .linkedLibrary("gpupixel", .when(platforms: [.iOS])),
    .linkedLibrary("angle", .when(platforms: [.iOS])),
    .linkedLibrary("yuv", .when(platforms: [.iOS])),
    .linkedLibrary("bgfx", .when(platforms: [.iOS])),
    .linkedLibrary("tflite", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-fp16arith", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-neonfp16arith", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-neonfp16arith_aarch64", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-neondot", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-neondot_aarch64", .when(platforms: [.iOS])),
    .linkedFramework("Metal", .when(platforms: [.iOS])),
    .linkedFramework("QuartzCore", .when(platforms: [.iOS])),
    .linkedFramework("CoreMedia", .when(platforms: [.iOS])),
    .linkedFramework("CoreVideo", .when(platforms: [.iOS])),
    .linkedFramework("IOSurface", .when(platforms: [.iOS])),
    .linkedFramework("VideoToolbox", .when(platforms: [.iOS])),
    .linkedFramework("AVFoundation", .when(platforms: [.iOS])),
]

let package = Package(
    name: "Gosslens",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Gosslens", targets: ["Gosslens"]),
    ],
    targets: [
        .target(name: "CGosslens", path: "Sources/CGosslens"),
        .target(
            name: "Gosslens",
            dependencies: ["CGosslens"],
            path: "Sources/Gosslens",
            linkerSettings: engineLinkerSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
