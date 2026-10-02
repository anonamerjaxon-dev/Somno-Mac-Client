// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CursorChanger",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "CursorChanger",
            targets: ["CursorChanger"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CursorChanger",
            dependencies: [],
            path: "Sources/CursorChanger",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "TestRunner",
            dependencies: ["CursorChanger"],
            path: "Tests/TestRunner"
        ),
        .executableTarget(
            name: "CursorChangerDemo",
            dependencies: ["CursorChanger"],
            path: "Examples/CursorChangerDemo"
        ),
        .executableTarget(
            name: "CursorChangerCLI",
            dependencies: ["CursorChanger"],
            path: "Sources/CursorChangerCLI"
        ),
        .executableTarget(
            name: "CursorChangerAgent",
            dependencies: ["CursorChanger"],
            path: "Examples/CursorChangerAgent"
        )
    ]
)
