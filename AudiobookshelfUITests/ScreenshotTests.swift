import XCTest

#if os(macOS)
    import AppKit
#endif

/// App Store screenshots (#109): the fixture journey (`FixtureJourney.swift`), attaching a full-screen screenshot of
/// each screen named `appstore-<screen>`. `scripts/screenshots.sh` (`mise run screenshots`) runs this class on each
/// device and locale and exports the attachments to `build/screenshots/`; see docs/testing/screenshots.md.
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

    /// Home, Library and *Pride and Prejudice*.
    // TODO(#109): add Player, Downloads and Settings with #106b's navigation helpers, and their names to SCREENS in
    // scripts/screenshots.sh.
    @MainActor
    func testHomeLibraryAndItem() {
        let app = signIn(launchArguments: Self.localeArguments + Self.noRestorationArguments)
        #if os(macOS)
            enterFullScreen(app)
        #endif
        capture("home")

        app.descendants(matching: .any)["tab.library"].firstMatch.press()
        let item = app.descendants(matching: .any)["library.screen"].descendants(matching: .any)["item.li_pride"]
        XCTAssertTrue(item.waitForExistence(timeout: Self.fixtureTimeout), "The library's items didn't appear")
        capture("library")

        // Already on Library, so this opens the item and checks its title.
        openLibraryItem(in: app)
        capture("item")
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
