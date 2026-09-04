// swift-tools-version:6.3
import PackageDescription

// The from-source manifest, for a fork or a local engine build: `cd sdk/swift
// && swift build` resolves this one. A consumer adding the package by URL
// resolves the repository-root manifest instead, which downloads the release
// XCFramework and needs no Zig.

// The engine links as the static archives `zig build ios` and `ios-simulator` install into
// zig-out — every one of them. The list used to name vender libs, so a build from
// source failed to link on the first symbol from an omitted archive (quickjs, jolt, ruy and the
// rest of the tflite kernels), which only a from-source consumer would ever hit. Naming them here means a build points
// LIBRARY_SEARCH_PATHS at that directory per slice instead of hand-copying
// the -l list out of the demo; docs/INTEGRATION-iOS.md is the guide.
let engineLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("absl", .when(platforms: [.iOS])),
    .linkedLibrary("angle", .when(platforms: [.iOS])),
    .linkedLibrary("bgfx", .when(platforms: [.iOS])),
    .linkedLibrary("cpuinfo", .when(platforms: [.iOS])),
    .linkedLibrary("farmhash", .when(platforms: [.iOS])),
    .linkedLibrary("fft2d", .when(platforms: [.iOS])),
    .linkedLibrary("flatbuffers", .when(platforms: [.iOS])),
    .linkedLibrary("gosslens", .when(platforms: [.iOS])),
    .linkedLibrary("gpupixel", .when(platforms: [.iOS])),
    .linkedLibrary("jolt", .when(platforms: [.iOS])),
    .linkedLibrary("pthreadpool", .when(platforms: [.iOS])),
    .linkedLibrary("quickjs", .when(platforms: [.iOS])),
    .linkedLibrary("ruy", .when(platforms: [.iOS])),
    .linkedLibrary("tflite", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-aarch64", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-fp16arith", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-neondot", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-neondot_aarch64", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-neondotfp16arith", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-neonfp16arith", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-neonfp16arith_aarch64", .when(platforms: [.iOS])),
    .linkedLibrary("xnnpack-neoni8mm", .when(platforms: [.iOS])),
    .linkedLibrary("yuv", .when(platforms: [.iOS])),
    // The system libraries the archives above were compiled against: angle's zlib calls and
    // every C++ vendor's runtime. Named here because a static archive carries neither.
    .linkedLibrary("z", .when(platforms: [.iOS])),
    .linkedLibrary("c++", .when(platforms: [.iOS])),
    // The Neural Engine path: tflite's CoreML delegate is compiled into libtflite.a, so a
    // consumer of these archives links CoreML the same way it links Metal.
    .linkedFramework("CoreML", .when(platforms: [.iOS])),
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
