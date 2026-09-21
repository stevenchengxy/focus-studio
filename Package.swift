// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FocusStudio",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .library(name: "FocusStudioCore", targets: ["FocusStudioCore"]),
        .library(name: "FocusStudioCapture", targets: ["FocusStudioCapture"]),
        .executable(name: "FocusStudio", targets: ["FocusStudio"]),
        .executable(name: "FocusStudioE2E", targets: ["FocusStudioE2E"]),
        .executable(name: "FocusStudioPermissionTests", targets: ["FocusStudioPermissionTests"])
    ],
    targets: [
        .target(
            name: "FocusStudioCore",
            path: "Sources/FocusStudioCore"
        ),
        .target(
            name: "FocusStudioCapture",
            dependencies: ["FocusStudioCore"],
            path: "Sources/FocusStudio/Capture"
        ),
        .executableTarget(
            name: "FocusStudio",
            dependencies: ["FocusStudioCore", "FocusStudioCapture"],
            path: "Sources/FocusStudio",
            exclude: ["Capture"]
        ),
        .executableTarget(
            name: "FocusStudioE2E",
            dependencies: ["FocusStudioCore", "FocusStudioCapture"],
            path: "Sources/FocusStudioE2E"
        ),
        .executableTarget(
            name: "FocusStudioPermissionTests",
            dependencies: ["FocusStudioCore", "FocusStudioCapture"],
            path: "Tests/FocusStudioPermissionTests"
        )
    ]
)
