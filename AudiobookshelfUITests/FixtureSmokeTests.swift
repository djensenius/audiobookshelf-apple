import XCTest

/// Launches the app against the fixture server (`-ABSFixtures`, see `FixtureServer`), connects
/// and signs in. UI tests use XCTest: `XCUIApplication` needs an XCTest UI test runner.
final class FixtureSmokeTests: XCTestCase {
    /// The fixture server's address, as `FixtureServer.address` in the app.
    private static let address = "https://fixtures.audiobookshelf.invalid"
    private static let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testConnectsAndSignsIn() {
        let app = XCUIApplication()
        app.launchArguments += ["-ABSFixtures"]
        app.launch()

        let address = app.textFields["connect.address"]
        XCTAssertTrue(address.waitForExistence(timeout: Self.timeout), "The connect screen didn't appear")
        address.press()
        address.typeText(Self.address)
        app.buttons["connect.submit"].press()

        let username = app.textFields["connect.username"]
        XCTAssertTrue(username.waitForExistence(timeout: Self.timeout), "The login screen didn't appear")
        username.press()
        username.typeText("fixture")
        let password = app.secureTextFields["connect.password"]
        password.press()
        password.typeText("fixture")
        app.buttons["connect.signIn"].press()

        let home = app.descendants(matching: .any)["home.screen"]
        XCTAssertTrue(home.waitForExistence(timeout: Self.timeout), "The signed-in shell didn't appear")
    }
}

extension XCUIElement {
    /// A click on macOS and a tap on iOS.
    fileprivate func press() {
        #if os(macOS)
            click()
        #else
            tap()
        #endif
    }
}
