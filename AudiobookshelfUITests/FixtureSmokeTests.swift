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

    @MainActor
    func testOpensLibraryItem() {
        openLibraryItem(in: signIn())
    }
}
