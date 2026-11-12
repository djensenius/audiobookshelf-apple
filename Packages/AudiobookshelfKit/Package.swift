// swift-tools-version: 6.4

import PackageDescription

// Every planned module is declared up front so parallel feature PRs add source files
// without conflicting on this manifest. The app links the single `AudiobookshelfKit`
// umbrella product and imports the individual modules it needs.
let package = Package(
    name: "AudiobookshelfKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v27),
        .macOS(.v27),
    ],
    products: [
        .library(
            name: "AudiobookshelfKit",
            targets: [
                "ABSCore", "ABSAPI", "ABSRealtime", "ABSData", "ABSPlayback", "ABSDownloads", "ABSUI",
                "ABSAppModel",
            ]
        )
    ],
    dependencies: [
        // CBZ comic archives (ADR 0008), the only approved third-party package. Pinned exactly.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        // Models and shared utilities.
        .target(name: "ABSCore"),
        .testTarget(name: "ABSCoreTests", dependencies: ["ABSCore"], resources: [.copy("Fixtures")]),

        // HTTP client, authentication, and endpoints.
        .target(name: "ABSAPI", dependencies: ["ABSCore"]),
        .testTarget(name: "ABSAPITests", dependencies: ["ABSAPI"], resources: [.copy("Fixtures")]),

        // Socket.IO real-time updates.
        .target(name: "ABSRealtime", dependencies: ["ABSCore", "ABSAPI"]),
        .testTarget(name: "ABSRealtimeTests", dependencies: ["ABSRealtime"]),

        // SwiftData persistence.
        .target(name: "ABSData", dependencies: ["ABSCore"]),
        .testTarget(name: "ABSDataTests", dependencies: ["ABSData"]),

        // Audio playback and progress sync.
        .target(name: "ABSPlayback", dependencies: ["ABSCore", "ABSAPI", "ABSData"]),
        .testTarget(name: "ABSPlaybackTests", dependencies: ["ABSPlayback"], resources: [.copy("Fixtures")]),

        // Offline downloads.
        .target(name: "ABSDownloads", dependencies: ["ABSCore", "ABSAPI", "ABSData"]),
        .testTarget(name: "ABSDownloadsTests", dependencies: ["ABSDownloads"]),

        // Opt-in contract tests against a real Audiobookshelf server (`mise run test:server`).
        // They are skipped unless ABS_TEST_SERVER_URL is set.
        .testTarget(name: "ABSServerContractTests", dependencies: ["ABSCore", "ABSAPI", "ABSData"]),

        // Shared SwiftUI components and design system.
        .target(name: "ABSUI", dependencies: ["ABSCore"], resources: [.process("Resources")]),
        .testTarget(name: "ABSUITests", dependencies: ["ABSUI"]),

        // Account and library state, routing, feature view models, and the realtime
        // bridge. Sits above every module except ABSUI and never imports ABSUI.
        .target(
            name: "ABSAppModel",
            dependencies: [
                "ABSCore", "ABSAPI", "ABSRealtime", "ABSData", "ABSPlayback", "ABSDownloads",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        // ZIPFoundation builds fixture comic archives at test time.
        .testTarget(
            name: "ABSAppModelTests",
            dependencies: ["ABSAppModel", .product(name: "ZIPFoundation", package: "ZIPFoundation")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
