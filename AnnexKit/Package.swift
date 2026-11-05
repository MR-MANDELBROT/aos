// swift-tools-version: 6.0
//
// AnnexKit: the engine behind the app (VM, guest setup, VNC, agent protocol, MCP).
// The Xcode project (project.yml) builds the app, the agent and the MCP tool from these targets;
// `swift build` and `swift test` work on their own for development.

import PackageDescription

let package = Package(
    name: "Annex",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "AnnexKit", targets: ["AnnexKit"]),
        .executable(name: "annexctl", targets: ["annexctl"]),
        .executable(name: "annex-mcp", targets: ["annex-mcp"]),
        .executable(name: "annex-session", targets: ["annex-session"]),
    ],
    targets: [
        .target(
            name: "AnnexKit",
            path: "Sources/AnnexKit",
            resources: [.copy("Resources/Guest")],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedFramework("Virtualization"),
            ]
        ),
        .executableTarget(name: "annexctl", dependencies: ["AnnexKit"], path: "Sources/annexctl"),
        .executableTarget(name: "annex-mcp", dependencies: ["AnnexKit"], path: "Sources/annex-mcp"),
        .executableTarget(name: "annex-session", dependencies: ["AnnexKit"], path: "Sources/annex-session"),
        .testTarget(name: "AnnexKitTests", dependencies: ["AnnexKit"], path: "Tests/AnnexKitTests"),
    ],
    swiftLanguageModes: [.v5]
)
