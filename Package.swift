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
            url: "https://github.com/myzonerocks/gosslens/releases/download/v0.11.0/GosslensKit.xcframework.zip",
            checksum: "fe31259e98d3ae4fcea67fd847b77f97ce1345a32295e7dff41929f06ea323bc"
        ),
        .target(
            name: "Gosslens",
            dependencies: ["GosslensKit"],
            path: "sdk/swift/Sources/Gosslens"
        ),
    ],
    swiftLanguageModes: [.v6]
)
