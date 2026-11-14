import XCTest

#if os(macOS)
    import AppKit
#endif

/// App Store screenshots (#109): the fixture journey (`FixtureJourney.swift`, `FixtureScreens.swift`), attaching a
/// full-screen screenshot of each screen named `appstore-<screen>`. `scripts/screenshots.sh` (`mise run screenshots`)
/// runs this class on each device and locale and exports the attachments to `build/screenshots/`; see
/// docs/testing/screenshots.md.
///
/// Skipped unless `ABS_SCREENSHOTS` is `1` (the script passes `TEST_RUNNER_ABS_SCREENSHOTS=1`), so `mise run test:ui`
/// and CI don't spend time on it.
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ABS_SCREENSHOTS"] == "1",
            "App Store screenshots run only from scripts/screenshots.sh (mise run screenshots)")
    }

    /// Home, Library, *Pride and Prejudice*, the player (paused), Settings, and Downloads with *Pride and Prejudice*
    /// downloaded, opened with `open(_:in:)` (`FixtureScreens.swift`).
    @MainActor
    func testAppStoreScreens() {
        let app = signIn(launchArguments: Self.localeArguments + Self.noRestorationArguments)
        #if os(macOS)
            enterFullScreen(app)
        #endif
        for screen in [FixtureScreen.home, .library, .item, .player, .settings] {
            open(screen, in: app)
            capture(screen.rawValue)
        }
        download(in: app)
        let downloads = open(.downloads, in: app)
        // The book's row; its title is fixture data, so it's the same in every language.
        let book = downloads.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Pride and Prejudice, ")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: Self.fixtureTimeout), "Downloads doesn't list the downloaded book")
        capture(FixtureScreen.downloads.rawValue)
    }

    /// Downloads *Pride and Prejudice* from its screen and waits until it's downloaded. The fixture server answers
    /// the download with the bundled audio (`FixtureServer.resource(method:path:)`).
    @MainActor
    private func download(in app: XCUIApplication) {
        open(.item, in: app)
        let download = app.buttons["item.download"].firstMatch
        XCTAssertTrue(download.waitForEnabled(timeout: Self.fixtureTimeout), "The item's Download button isn't enabled")
        download.press()
        XCTAssertTrue(
            app.buttons["item.downloaded"].firstMatch.waitForExistence(timeout: 60), "The download didn't finish")
    }

    /// `-AppleLanguages` and `-AppleLocale` for `ABS_SCREENSHOT_LOCALE` (a BCP 47 tag such as `en-US`, default
    /// `en-US`).
    private static var localeArguments: [String] {
        let tag = ProcessInfo.processInfo.environment["ABS_SCREENSHOT_LOCALE"] ?? "en-US"
        return ["-AppleLanguages", "(\(tag))", "-AppleLocale", tag.replacingOccurrences(of: "-", with: "_")]
    }

    /// On macOS, don't restore windows from an earlier run (such as one left full screen), so each launch starts
    /// from the same window state. These are AppKit defaults, set for this launch only.
    private static var noRestorationArguments: [String] {
        #if os(macOS)
            ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        #else
            []
        #endif
    }

    #if os(macOS)
        /// Makes the main window full screen on the main display, so that display shows only the app, and fails
        /// unless it is. ⌃⌘F toggles full screen, so it's pressed only when the window isn't already.
        @MainActor
        private func enterFullScreen(_ app: XCUIApplication) {
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: Self.fixtureTimeout), "The main window didn't appear")
            // XCUIScreen.main is the primary display, NSScreen.screens.first. It's at the origin both of NSScreen's
            // coordinates and of XCUIElement's (top left of the primary display), in points on both; checking the
            // origin as well as the size keeps a window full screen on another display of the same size out.
            guard let size = NSScreen.screens.first?.frame.size else {
                XCTFail("No display to capture")
                return
            }
            let screen = CGRect(origin: .zero, size: size)
            let isFullScreen = { window.frame == screen }
            if !isFullScreen() {
                app.typeKey("f", modifierFlags: [.command, .control])
            }
            let deadline = Date().addingTimeInterval(10)
            while !isFullScreen(), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
            }
            XCTAssertTrue(
                isFullScreen(),
                "The main window is \(window.frame), not full screen on the main display (\(screen)); the screenshot "
                    + "would show the desktop or another display's content. Move the app to the main display."
            )
        }
    #endif

    /// Attaches the whole main screen, status bar included, as `appstore-<screen>`, after a moment for covers and
    /// transitions to settle (a screenshot doesn't wait for the app to be idle).
    @MainActor
    private func capture(_ screen: String) {
        Thread.sleep(forTimeInterval: 1.5)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "appstore-\(screen)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
