import XCTest

/// The connection indicator (#59) stays in the compact bar when there's a problem (#691), even on the Library root,
/// whose bar is crowded with the library picker, the section menu, the filter and sort and the view options. A
/// fixture launch has no realtime socket, so `-ABSConnectionState` (`FixtureServer.connectionStateArgument`) forces
/// the state. The indicator outranks them only once the problem has lasted a few seconds (`ConnectionProblemDebounce`),
/// so the checks wait for it. A regular-width iPad and a Mac have room and keep their layouts, so the tests skip there.
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

    /// The worst case: offline with a download under way, on the Library root. The download queue indicator and the
    /// connection indicator both stay in the bar; the filter and sort make room in its overflow menu.
    @MainActor
    func testOfflineIndicatorAndQueueAreInTheCompactLibraryBar() throws {
        #if os(iOS)
            let app = signIn(launchArguments: ["-ABSConnectionState", "offline", "-ABSStallDownloads"])
            try XCTSkipUnless(
                app.windows.firstMatch.horizontalSizeClass == .compact, "A regular-width window has room for them")
            open(.item, in: app)
            let download = app.buttons["item.download"].firstMatch
            XCTAssertTrue(
                download.waitForEnabled(timeout: Self.fixtureTimeout), "The item's Download button isn't enabled")
            download.press()

            open(.library, in: app)
            let queue = app.buttons["downloads.queueIndicator"].firstMatch
            let indicator = app.buttons["connection.indicator"].firstMatch
            let queueExists = queue.waitForExistence(timeout: Self.fixtureTimeout)
            let indicatorExists = indicator.waitForExistence(timeout: Self.fixtureTimeout)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "connection-offline-downloading-library"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTAssertTrue(queueExists, "The Library's bar has no queue indicator")
            XCTAssertTrue(indicatorExists, "The Library's bar has no connection indicator")
            XCTAssertTrue(queue.isHittable, "The Library's queue indicator can't be pressed")
            XCTAssertTrue(indicator.isHittable, "The Library's connection indicator can't be pressed")
        #else
            throw XCTSkip("A Mac's toolbar has room for them")
        #endif
    }
}
