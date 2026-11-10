// swift-tools-version: 6.4

import PackageDescription

// Repository tool that generates ABSUI's Localizable.xcstrings from strings/*.json.
// Run it with `mise run strings`; it is not linked into the app.
let package = Package(
    name: "StringsImport",
    platforms: [.macOS(.v27)],
    targets: [
        .target(name: "StringsImportCore"),
        .executableTarget(name: "import-strings", dependencies: ["StringsImportCore"]),
        .testTarget(name: "StringsImportCoreTests", dependencies: ["StringsImportCore"]),
    ],
    swiftLanguageModes: [.v6]
)
