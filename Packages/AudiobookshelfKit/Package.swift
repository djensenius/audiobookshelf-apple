// swift-tools-version: 6.4

import PackageDescription

// Every planned module is declared up front so parallel feature PRs add source files
// without conflicting on this manifest. The app links the single `AudiobookshelfKit`
// umbrella product and imports the individual modules it needs.
let package = Package(
    name: "AudiobookshelfKit",
    platforms: [
        .iOS(.v27),
        .macOS(.v27),
    ],
    products: [
        .library(
            name: "AudiobookshelfKit",
            targets: ["ABSCore", "ABSAPI", "ABSRealtime", "ABSData", "ABSPlayback", "ABSDownloads", "ABSUI"]
        )
    ],
    targets: [
        // Models and shared utilities.
        .target(name: "ABSCore"),
        .testTarget(name: "ABSCoreTests", dependencies: ["ABSCore"]),

        // HTTP client, authentication, and endpoints.
        .target(name: "ABSAPI", dependencies: ["ABSCore"]),
        .testTarget(name: "ABSAPITests", dependencies: ["ABSAPI"]),

        // Socket.IO real-time updates.
        .target(name: "ABSRealtime", dependencies: ["ABSCore", "ABSAPI"]),
        .testTarget(name: "ABSRealtimeTests", dependencies: ["ABSRealtime"]),

        // SwiftData persistence.
        .target(name: "ABSData", dependencies: ["ABSCore"]),
        .testTarget(name: "ABSDataTests", dependencies: ["ABSData"]),

        // Audio playback and progress sync.
        .target(name: "ABSPlayback", dependencies: ["ABSCore", "ABSAPI", "ABSData"]),
        .testTarget(name: "ABSPlaybackTests", dependencies: ["ABSPlayback"]),

        // Offline downloads.
        .target(name: "ABSDownloads", dependencies: ["ABSCore", "ABSAPI", "ABSData"]),
        .testTarget(name: "ABSDownloadsTests", dependencies: ["ABSDownloads"]),

        // Shared SwiftUI components and design system.
        .target(name: "ABSUI", dependencies: ["ABSCore"]),
        .testTarget(name: "ABSUITests", dependencies: ["ABSUI"]),
    ],
    swiftLanguageModes: [.v6]
)
