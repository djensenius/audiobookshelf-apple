import XCTest

/// The fixture journey (`FixtureJourney.swift`) in other languages, attaching screenshots of Home,
/// Library and the item (kept with the result bundle; see docs/testing/ui-tests.md). The book's
/// title is server data, so it stays "Pride and Prejudice" in every language.
final class LocalizedSmokeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Arabic: a real right-to-left language.
    @MainActor
    func testArabic() {
        run(["-AppleLanguages", "(ar)", "-AppleLocale", "ar"], screenshotPrefix: "ar")
    }

    /// German: real translations that run long.
    @MainActor
    func testGerman() {
        run(["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"], screenshotPrefix: "de")
    }

    /// Xcode's double-length and right-to-left pseudolanguages together: every localized string
    /// repeated, in a mirrored layout. This stresses truncation and mirroring beyond Arabic and
    /// German, with English text that shows which strings are localized.
    @MainActor
    func testPseudoLanguage() {
        run(
            [
                "-NSDoubleLocalizedStrings", "YES",
                "-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES",
            ],
            screenshotPrefix: "pseudo")
    }

    @MainActor
    private func run(_ arguments: [String], screenshotPrefix: String) {
        let app = signIn(launchArguments: arguments, screenshotPrefix: screenshotPrefix)
        openLibraryItem(in: app, screenshotPrefix: screenshotPrefix)
    }
}
