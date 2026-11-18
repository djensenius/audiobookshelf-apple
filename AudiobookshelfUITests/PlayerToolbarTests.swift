import XCTest

/// The full player's bottom toolbar on an iPad in portrait (#705). The split arrangement shows the
/// details pane only side by side, in landscape; in portrait only the player shows, so the toolbar
/// must keep Chapters, Bookmarks and Up Next (#698). A unit test covers only the axis rule
/// (`SplitArrangement.showsSecondaryPane(axis:)`).
final class PlayerToolbarTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    #if os(iOS)
        /// The light theme and the default text size (Large), whatever the simulator's appearance and
        /// text size, as in `ChapterHighlightTests`: at accessibility sizes the bar can move buttons
        /// into its overflow menu.
        private static let launchArguments = [
            "-ABSTheme", "light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        ]

        /// On an iPad from iOS 27.1, where the player has arrangements (as in `NowPlayingView`), turned
        /// to portrait (and afterwards back to the orientation it had), the player's toolbar shows
        /// Chapters, Bookmarks and Up Next, each hittable. Elsewhere it's skipped.
        @MainActor
        func testPortraitToolbarShowsChaptersBookmarksAndUpNext() throws {
            try XCTSkipUnless(
                UIDevice.current.userInterfaceIdiom == .pad, "Only an iPad's player has the split arrangement")
            guard #available(iOS 27.1, *) else { throw XCTSkip("The player has arrangements from iOS 27.1") }
            let initial = XCUIDevice.shared.orientation
            addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = initial }
            XCUIDevice.shared.orientation = .portrait
            let app = signIn(launchArguments: Self.launchArguments)
            open(.player, in: app)

            for (identifier, name) in [
                ("player.chapters", "Chapters"), ("player.bookmarks", "Bookmarks"), ("player.queue", "Up Next"),
            ] {
                let button = app.buttons[identifier].firstMatch
                XCTAssertTrue(
                    button.waitForExistence(timeout: Self.fixtureTimeout), "The portrait toolbar has no \(name) button")
                XCTAssertTrue(button.isHittable, "The portrait toolbar's \(name) button isn't hittable")
            }
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "portrait-toolbar"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    #endif
}
