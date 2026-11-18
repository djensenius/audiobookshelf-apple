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

        /// In regular width, where the queue is an inspector beside the content rather than a sheet,
        /// the mini player's play/pause and close stay reachable while the inspector is open (#687).
        @MainActor
        func testQueueInspectorLeavesMiniPlayerControlsReachable() throws {
            try checkQueueInspectorLeavesMiniPlayerControlsReachable()
        }

        /// The same in a right-to-left layout, where the inspector is on the left (#687).
        @MainActor
        func testQueueInspectorLeavesMiniPlayerControlsReachableRightToLeft() throws {
            try checkQueueInspectorLeavesMiniPlayerControlsReachable(launchArguments: [
                "-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES",
            ])
        }

        @MainActor
        private func checkQueueInspectorLeavesMiniPlayerControlsReachable(launchArguments: [String] = []) throws {
            let app = signIn(launchArguments: launchArguments)
            try XCTSkipUnless(
                app.windows.firstMatch.horizontalSizeClass == .regular,
                "Compact width shows the queue as a sheet over the mini player")
            showMiniPlayer(in: app)
            let mini = app.descendants(matching: .any)["player.mini"].firstMatch
            mini.press(forDuration: 1.5)
            let upNext = app.buttons["player.mini.upNext"].firstMatch
            XCTAssertTrue(upNext.waitForExistence(timeout: Self.fixtureTimeout), "The Up Next menu didn't appear")
            upNext.press()
            let inspector = app.descendants(matching: .any)["queue.inspector"].firstMatch
            XCTAssertTrue(inspector.waitForExistence(timeout: Self.fixtureTimeout), "The queue inspector didn't open")

            // The full player's buttons can be in the tree too; only those in the bar count.
            func inBar(_ identifier: String) -> XCUIElement? {
                app.buttons.matching(identifier: identifier).allElementsBoundByIndex
                    .first { mini.frame.minY...mini.frame.maxY ~= $0.frame.midY }
            }
            // The bar makes room once the inspector is in place.
            func hittableInBar(_ identifier: String) -> XCUIElement? {
                var button: XCUIElement?
                _ = wait(
                    for: {
                        button = inBar(identifier)
                        return button?.isHittable == true
                    }, timeout: Self.fixtureTimeout)
                return button
            }
            let close = try XCTUnwrap(hittableInBar("player.mini.close"), "The mini player's close button isn't there")
            XCTAssertTrue(close.isHittable, "The queue inspector covers the mini player's close button")
            // On whichever side the inspector is.
            XCTAssertTrue(
                close.frame.maxX <= inspector.frame.minX || close.frame.minX >= inspector.frame.maxX,
                "The mini player's close button (\(close.frame)) is under the queue inspector (\(inspector.frame))")
            let play = try XCTUnwrap(
                hittableInBar("player.play"), "The queue inspector covers the mini player's play button")
            XCTAssertTrue(play.isHittable, "The queue inspector covers the mini player's play button")
            // A press reaches it: playback starts, so the bar shows pause.
            play.press()
            XCTAssertTrue(
                wait(for: { inBar("player.pause") != nil }, timeout: Self.fixtureTimeout),
                "The mini player's play didn't play")
            XCTAssertTrue(inspector.exists, "The queue inspector closed")
        }

        /// Signs in, plays the fixture book (`open(_:in:)`'s player) and opens Settings, under the
        /// mini player.
        @MainActor
        private func showMiniPlayer(launchArguments: [String] = []) -> XCUIApplication {
            let app = signIn(launchArguments: launchArguments)
            showMiniPlayer(in: app)
            return app
        }

        /// Plays the fixture book and opens Settings, under the mini player, in a signed-in `app`.
        @MainActor
        private func showMiniPlayer(in app: XCUIApplication) {
            open(.player, in: app)
            open(.settings, in: app)
            let mini = app.descendants(matching: .any)["player.mini"].firstMatch
            XCTAssertTrue(mini.waitForExistence(timeout: Self.fixtureTimeout), "The mini player isn't there")
        }
    #endif
}
