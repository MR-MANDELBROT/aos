// swift-tools-version: 6.0
//
// AOSKit: the engine behind the app (VM, guest setup, VNC, agent protocol, MCP).
// The Xcode project (project.yml) builds the app, the agent and the MCP tool from these targets;
// `swift build` and `swift test` work on their own for development.

import PackageDescription

let package = Package(
    name: "aOS",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "AOSKit", targets: ["AOSKit"]),
        // The screen sharing (RFB) client, shared with the iPhone app
        .library(name: "AOSRFB", targets: ["AOSRFB"]),
        .executable(name: "aosctl", targets: ["aosctl"]),
        .executable(name: "aos-mcp", targets: ["aos-mcp"]),
        .executable(name: "aos-session", targets: ["aos-session"]),
        .executable(name: "aos-companion", targets: ["aos-companion"]),
        .executable(name: "aos-powerd", targets: ["aos-powerd"]),
        .executable(name: "aos-guest-helper", targets: ["aos-guest-helper"]),
    ],
    targets: [
        .target(
            name: "AOSRFB",
            path: "Sources/AOSRFB",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "AOSKit",
            dependencies: ["AOSRFB"],
            path: "Sources/AOSKit",
            resources: [.copy("Resources/Guest")],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedFramework("Virtualization"),
            ]
        ),
        .executableTarget(name: "aosctl", dependencies: ["AOSKit"], path: "Sources/aosctl"),
        .executableTarget(name: "aos-mcp", dependencies: ["AOSKit"], path: "Sources/aos-mcp"),
        .executableTarget(name: "aos-session", dependencies: ["AOSKit"], path: "Sources/aos-session"),
        .executableTarget(name: "aos-companion", dependencies: ["AOSKit"], path: "Sources/aos-companion"),
        // The privileged helper (root LaunchDaemon from the app bundle): sleep with the lid closed and Wi-Fi settings.
        .executableTarget(name: "aos-powerd", dependencies: ["AOSKit"], path: "Sources/aos-powerd"),
        // Runs inside the workspace (its own app bundle there, see project.yml); depends on nothing of aOS.
        .executableTarget(name: "aos-guest-helper", path: "Sources/aos-guest-helper"),
        .testTarget(name: "AOSKitTests", dependencies: ["AOSKit", "AOSRFB"], path: "Tests/AOSKitTests"),
    ],
    swiftLanguageModes: [.v5]
)
