// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DesktopCanvas",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "DesktopCanvas",
            targets: ["DesktopCanvas"]
        ),
        .executable(
            name: "DesktopCanvasTest",
            targets: ["DesktopCanvasTest"]
        ),
        .executable(
            name: "DesktopCanvasDemo",
            targets: ["DesktopCanvasDemo"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "DesktopCanvas",
            dependencies: [],
            path: "Sources/DesktopCanvas",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("QuartzCore")
            ]
        ),
        .executableTarget(
            name: "DesktopCanvasTest",
            dependencies: ["DesktopCanvas"],
            path: "Sources/DesktopCanvasTest"
        ),
        .executableTarget(
            name: "DesktopCanvasDemo",
            dependencies: ["DesktopCanvas"],
            path: "Sources/DesktopCanvasDemo",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .testTarget(
            name: "DesktopCanvasTests",
            dependencies: ["DesktopCanvas"],
            path: "Tests/DesktopCanvasTests"
        )
    ]
)