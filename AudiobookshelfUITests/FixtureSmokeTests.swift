import XCTest

/// Launches the app against the fixture server (`-ABSFixtures`, see `FixtureServer`), connects
/// and signs in, then walks Home → Library → item. UI tests use XCTest: `XCUIApplication` needs an
/// XCTest UI test runner.
final class FixtureSmokeTests: XCTestCase {
    /// The fixture server's address, as `FixtureServer.address` in the app.
    private static let address = "https://fixtures.audiobookshelf.invalid"
    private static let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testConnectsAndSignsIn() {
        signIn()
    }

    @MainActor
    func testOpensLibraryItem() {
        let app = signIn()

        app.descendants(matching: .any)["tab.library"].firstMatch.press()
        let library = app.descendants(matching: .any)["library.screen"]
        XCTAssertTrue(library.waitForExistence(timeout: Self.timeout), "The Library screen didn't appear")

        // The first card of `fixture-items.json`.
        let item = library.descendants(matching: .any)["item.li_pride"]
        XCTAssertTrue(item.waitForExistence(timeout: Self.timeout), "The library's items didn't appear")
        item.press()

        let detail = app.descendants(matching: .any)["item.detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: Self.timeout), "The item screen didn't appear")
        let title = detail.descendants(matching: .any)["item.title"]
        XCTAssertTrue(title.waitForExistence(timeout: Self.timeout), "The item didn't load")
        XCTAssertEqual(title.label, "Pride and Prejudice")
    }

    /// Launches with the fixtures, connects, signs in and waits for Home.
    @MainActor
    @discardableResult
    private func signIn() -> XCUIApplication {
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
        return app
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
