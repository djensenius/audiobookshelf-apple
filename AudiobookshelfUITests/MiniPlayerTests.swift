import XCTest

/// The mini player's layout in narrow windows and its long press (#616, #624), on iOS.
///
/// The Large Content Viewer itself isn't checked: XCUITest's `press(forDuration:)` returns only
/// once the finger lifts, which dismisses the viewer's HUD, so the HUD can't be queried while it's
/// up. These tests check what can be: the Up Next menu that the long press shows instead at
/// smaller sizes, and that it's gone at accessibility sizes, where the viewer takes the long press.
final class MiniPlayerTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    #if os(iOS)
        /// The width the title keeps before the jumps give way (`readableTitleWidth` at the default
        /// size), less a little for rounding.
        private static let readableTitleWidth: CGFloat = 105
        /// Below this bar width the full row (cover, readable title, jumps, play/pause, close) can't
        /// fit, so the jumps go; above `wideBarWidth` it fits. In between, either is right.
        private static let narrowBarWidth: CGFloat = 370
        private static let wideBarWidth: CGFloat = 440

        /// At the default size the title keeps a readable width; in a narrow window, such as the
        /// iPhone Duo's that CI uses, the jumps go to make room, and in a wide one they stay.
        @MainActor
        func testNarrowWindowKeepsReadableTitle() {
            let app = showMiniPlayer()
            let mini = app.descendants(matching: .any)["player.mini"].firstMatch
            let close = app.buttons["player.mini.close"].firstMatch
            XCTAssertTrue(
                close.waitForExistence(timeout: Self.fixtureTimeout), "The mini player's close button isn't there")
            let barWidth = close.frame.maxX - mini.frame.minX
            let title = app.descendants(matching: .any)["player.mini.title"].firstMatch
            XCTAssertTrue(title.exists, "The mini player's title isn't there")
            XCTAssertGreaterThanOrEqual(
                title.frame.width, Self.readableTitleWidth, "The title is \(title.frame.width) pt wide")

            let jumps = app.buttons.matching(
                NSPredicate(format: "identifier IN %@", ["player.jumpBackward", "player.jumpForward"]))
            // The full player's jumps can be in the tree too; only those in the bar count.
            let jumpsInBar = jumps.allElementsBoundByIndex.filter { mini.frame.minY...mini.frame.maxY ~= $0.frame.midY }
            if barWidth < Self.narrowBarWidth {
                XCTAssertTrue(jumpsInBar.isEmpty, "A \(barWidth) pt bar shows the jumps")
            } else if barWidth > Self.wideBarWidth {
                XCTAssertEqual(jumpsInBar.count, 2, "A \(barWidth) pt bar hides the jumps")
            }
        }

        /// At the default size, a long press on the title shows the Up Next menu.
        @MainActor
        func testLongPressShowsUpNextMenu() {
            let app = showMiniPlayer()
            let mini = app.descendants(matching: .any)["player.mini"].firstMatch
            mini.press(forDuration: 1.5)
            let upNext = app.buttons["player.mini.upNext"].firstMatch
            XCTAssertTrue(upNext.waitForExistence(timeout: 5), "The Up Next menu didn't appear")
            // Dismiss it with a tap away from it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
            XCTAssertTrue(upNext.waitForNonExistence(timeout: 5), "The Up Next menu didn't close")
        }

        /// At AX5, a long press on the title doesn't show the Up Next menu: the Large Content Viewer
        /// has the long press.
        @MainActor
        func testLongPressAtAccessibilitySizeShowsNoMenu() {
            let app = showMiniPlayer(launchArguments: [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            ])
            app.descendants(matching: .any)["player.mini"].firstMatch.press(forDuration: 1.5)
            XCTAssertFalse(
                app.buttons["player.mini.upNext"].firstMatch.waitForExistence(timeout: 3),
                "The Up Next menu took the long press from the Large Content Viewer")
        }

        /// Signs in, plays the fixture book (`open(_:in:)`'s player) and opens Settings, under the
        /// mini player.
        @MainActor
        private func showMiniPlayer(launchArguments: [String] = []) -> XCUIApplication {
            let app = signIn(launchArguments: launchArguments)
            open(.player, in: app)
            open(.settings, in: app)
            let mini = app.descendants(matching: .any)["player.mini"].firstMatch
            XCTAssertTrue(mini.waitForExistence(timeout: Self.fixtureTimeout), "The mini player isn't there")
            return app
        }
    #endif
}
