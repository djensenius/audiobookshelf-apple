import XCTest

/// Launches the app against the fixture server (`-ABSFixtures`, see `FixtureServer`), connects
/// and signs in, then walks Home → Library → item (`FixtureJourney.swift`). UI tests use XCTest:
/// `XCUIApplication` needs an XCTest UI test runner.
final class FixtureSmokeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testConnectsAndSignsIn() {
        signIn()
    }

    /// Also checks the item shows Download: the fixture book has a track and the fixture user may
    /// download. It once never appeared, as the task that builds its model sat on an empty `Group`.
    @MainActor
    func testOpensLibraryItem() {
        let app = signIn()
        openLibraryItem(in: app)
        XCTAssertTrue(
            app.buttons["item.download"].firstMatch.waitForExistence(timeout: Self.fixtureTimeout),
            "Pride and Prejudice has no Download button")
    }
}
