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
        .library(name: "FocusStudioAutomation", targets: ["FocusStudioAutomation"]),
        .executable(name: "FocusStudio", targets: ["FocusStudio"]),
        .executable(name: "FocusStudioE2E", targets: ["FocusStudioE2E"]),
        .executable(name: "FocusStudioPermissionTests", targets: ["FocusStudioPermissionTests"]),
        .executable(name: "focus-studio-mcp", targets: ["FocusStudioMCP"])
    ],
    dependencies: [
        // The official MCP Swift SDK, pinned exactly (Package.resolved is
        // committed). Only Sources/FocusStudioMCP/MCPSDKAdapter.swift uses it.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
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
        .target(
            name: "FocusStudioAutomation",
            dependencies: ["FocusStudioCore"],
            path: "Sources/FocusStudioAutomation"
        ),
        .executableTarget(
            name: "FocusStudio",
            dependencies: ["FocusStudioCore", "FocusStudioCapture", "FocusStudioAutomation"],
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
        ),
        // focus-studio-mcp: the stdio MCP server that Claude Code, Codex and
        // other MCP clients start; shipped in Focus Studio.app/Contents/MacOS.
        .executableTarget(
            name: "FocusStudioMCP",
            dependencies: [
                "FocusStudioAutomation",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/FocusStudioMCP"
        )
    ]
)
