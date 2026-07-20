// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CortexKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        // The umbrella — pulls in everything. Most apps want this.
        .library(name: "CortexKit", targets: ["CortexKit"]),
        // Granular products, so a consumer can take just one slice (e.g. a CLI
        // tool that only needs CortexAI, with no SwiftUI link cost).
        .library(name: "CortexUI", targets: ["CortexUI"]),
        .library(name: "CortexAI", targets: ["CortexAI"]),
        .library(name: "CortexInfra", targets: ["CortexInfra"]),
        .library(name: "CortexHelpers", targets: ["CortexHelpers"]),
    ],
    targets: [
        // Umbrella: re-exports the four modules so `import CortexKit` is enough.
        .target(
            name: "CortexKit",
            dependencies: ["CortexUI", "CortexAI", "CortexInfra", "CortexHelpers"]
        ),

        // Visual identity: Brand, Aurora, Liquid Glass, animation tokens, etc.
        // Depends on Infra only for the namespaced preference store that backs
        // the accent-theme selection.
        .target(
            name: "CortexUI",
            dependencies: ["CortexInfra"]
        ),

        // AI via the user's local CLI (claude / codex). No SwiftUI.
        .target(
            name: "CortexAI",
            dependencies: ["CortexInfra"]
        ),

        // Plumbing with no UI: Keychain, namespaced prefs, shell runner.
        // Zero dependencies — the root of the graph.
        .target(name: "CortexInfra"),

        // Small reusable SwiftUI pieces: JSON highlighter, search highlight,
        // skeleton loaders, markdown renderer. Depend on CortexUI for Brand.
        .target(
            name: "CortexHelpers",
            dependencies: ["CortexUI"]
        ),

        .testTarget(
            name: "CortexKitTests",
            dependencies: ["CortexAI", "CortexInfra", "CortexHelpers"]
        ),
    ]
)
