import XCTest

/// The fixture journey shared by `FixtureSmokeTests` and `LocalizedSmokeTests`: launch with the
/// fixtures (`-ABSFixtures`, see `FixtureServer`), connect, sign in, then Home → Library → item.
/// Every step finds elements by accessibility identifier, so it runs in any language.
extension XCTestCase {
    /// The fixture server's address, as `FixtureServer.address` in the app.
    private static var fixtureAddress: String { "https://fixtures.audiobookshelf.invalid" }
    static var fixtureTimeout: TimeInterval { 20 }

    /// Launches with the fixtures and `launchArguments`, connects, signs in and waits for Home.
    /// With a `screenshotPrefix`, attaches a screenshot of Home named `<prefix>-home`.
    @MainActor
    @discardableResult
    func signIn(launchArguments: [String] = [], screenshotPrefix: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ABSFixtures"] + launchArguments
        app.launch()

        let address = app.textFields["connect.address"]
        XCTAssertTrue(address.waitForExistence(timeout: Self.fixtureTimeout), "The connect screen didn't appear")
        address.press()
        address.typeText(Self.fixtureAddress)
        app.buttons["connect.submit"].press()

        let username = app.textFields["connect.username"]
        XCTAssertTrue(username.waitForExistence(timeout: Self.fixtureTimeout), "The login screen didn't appear")
        username.press()
        username.typeText("fixture")
        let password = app.secureTextFields["connect.password"]
        password.press()
        password.typeText("fixture")
        app.buttons["connect.signIn"].press()

        let home = app.descendants(matching: .any)["home.screen"]
        XCTAssertTrue(home.waitForExistence(timeout: Self.fixtureTimeout), "The signed-in shell didn't appear")
        attachScreenshot(of: app, prefix: screenshotPrefix, screen: "home")
        return app
    }

    /// Opens the Library tab, then *Pride and Prejudice*, and checks its title. With a
    /// `screenshotPrefix`, attaches `<prefix>-library` and `<prefix>-item`.
    @MainActor
    func openLibraryItem(in app: XCUIApplication, screenshotPrefix: String? = nil) {
        app.descendants(matching: .any)["tab.library"].firstMatch.press()
        let library = app.descendants(matching: .any)["library.screen"]
        XCTAssertTrue(library.waitForExistence(timeout: Self.fixtureTimeout), "The Library screen didn't appear")

        // The first card of `fixture-items.json`.
        let item = library.descendants(matching: .any)["item.li_pride"]
        XCTAssertTrue(item.waitForExistence(timeout: Self.fixtureTimeout), "The library's items didn't appear")
        attachScreenshot(of: app, prefix: screenshotPrefix, screen: "library")
        item.press()

        let detail = app.descendants(matching: .any)["item.detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: Self.fixtureTimeout), "The item screen didn't appear")
        let title = detail.descendants(matching: .any)["item.title"]
        XCTAssertTrue(title.waitForExistence(timeout: Self.fixtureTimeout), "The item didn't load")
        // Server data isn't localized, so the title is the same in every language.
        XCTAssertEqual(title.label, "Pride and Prejudice")
        attachScreenshot(of: app, prefix: screenshotPrefix, screen: "item")
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, prefix: String?, screen: String) {
        guard let prefix else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(prefix)-\(screen)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension XCUIElement {
    /// A click on macOS and a tap on iOS.
    func press() {
        #if os(macOS)
            click()
        #else
            tap()
        #endif
    }
}
