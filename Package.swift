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
            url: "https://github.com/myzonerocks/gosslens/releases/download/v0.12.0-alpha.6/GosslensKit.xcframework.zip",
            checksum: "179b2b15da634cc18ae97d23eaf1d676627384cf1f0482c0d069de25d390763c"
        ),
        .target(
            name: "Gosslens",
            dependencies: ["GosslensKit"],
            path: "sdk/swift/Sources/Gosslens"
        ),
    ],
    swiftLanguageModes: [.v6]
)
