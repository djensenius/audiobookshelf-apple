import XCTest

/// The connection indicator (#59) stays in the compact bar when there's a problem (#691), even on the Library root,
/// whose bar is crowded with the library picker, the section menu, the filter and sort and the view options. A
/// fixture launch has no realtime socket, so `-ABSConnectionState` (`FixtureServer.connectionStateArgument`) forces
/// the state. A regular-width iPad and a Mac have room and keep their layouts, so the test skips there.
final class ConnectionIndicatorTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testOfflineIndicatorIsInTheCompactBar() throws {
        #if os(iOS)
            let app = signIn(launchArguments: ["-ABSConnectionState", "offline"])
            try XCTSkipUnless(
                app.windows.firstMatch.horizontalSizeClass == .compact, "A regular-width window has room for it")
            let indicator = app.buttons["connection.indicator"].firstMatch
            for screen in [FixtureScreen.home, .library] {
                open(screen, in: app)
                // A bar's overflow menu isn't in the hierarchy until it opens, so an item moved there doesn't exist.
                let exists = indicator.waitForExistence(timeout: Self.fixtureTimeout)
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "connection-offline-\(screen.rawValue)"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                XCTAssertTrue(exists, "\(screen.name)'s bar has no connection indicator")
                XCTAssertTrue(indicator.isHittable, "\(screen.name)'s connection indicator can't be pressed")
            }
        #else
            throw XCTSkip("A Mac's toolbar has room for it")
        #endif
    }
}
