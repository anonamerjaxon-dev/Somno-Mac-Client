// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GhostTrail",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GhostTrail", targets: ["GhostTrail"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "GhostTrail",
            dependencies: [],
            path: "Sources/GhostTrail",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "GhostTrailDemo",
            dependencies: ["GhostTrail"],
            path: "Examples/GhostTrailDemo"
        ),
        .executableTarget(
            name: "GhostTrailProbe",
            dependencies: ["GhostTrail"],
            path: "Examples/GhostTrailProbe"
        ),
        .testTarget(
            name: "GhostTrailTests",
            dependencies: ["GhostTrail"],
            path: "Tests/GhostTrailTests"
        )
    ]
)