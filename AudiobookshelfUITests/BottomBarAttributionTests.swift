import XCTest

/// ``BottomBarAttribution``'s decisions, without launching the app. #647
final class BottomBarAttributionTests: XCTestCase {
    private typealias Step = BottomBarAttribution.Step

    /// The issue goes away while the original view is still on screen: attributed.
    func testIssueGoneWithTheViewOnScreenIsAttributed() {
        let step = Step(unnamedIssues: 0, namedFailures: 0, originalViewVisible: true)
        XCTAssertEqual(BottomBarAttribution.outcome(after: step, canScrollFurther: true), .attributed)
        XCTAssertEqual(BottomBarAttribution.outcome(after: step, canScrollFurther: false), .attributed)
    }

    /// The issue persists, and another step can still scroll: undecided.
    func testIssuePersistingWithRoomToScrollIsUndecided() {
        let step = Step(unnamedIssues: 1, namedFailures: 0, originalViewVisible: true)
        XCTAssertEqual(BottomBarAttribution.outcome(after: step, canScrollFurther: true), .undecided)
    }

    /// The issue persists as far as the view allows: not attributed, so the original failure stands.
    func testIssuePersistingWithNoRoomLeftIsNotAttributed() {
        let step = Step(unnamedIssues: 1, namedFailures: 0, originalViewVisible: true)
        XCTAssertEqual(
            BottomBarAttribution.outcome(after: step, canScrollFurther: false), .notAttributed(.persisted))
    }

    /// Text from the original view left it: not attributed, even if the issue went with it.
    func testViewLeavingIsNotAttributed() {
        for unnamed in [0, 1] {
            let step = Step(unnamedIssues: unnamed, namedFailures: 0, originalViewVisible: false)
            XCTAssertEqual(
                BottomBarAttribution.outcome(after: step, canScrollFurther: true), .notAttributed(.viewLeft))
        }
    }

    /// Text from the original view or under the bar fails by name: failed, whatever else the step found.
    func testNamedFailureOnTheViewOrTheContentFails() {
        for (unnamed, visible) in [(0, true), (1, true), (0, false)] {
            let step = Step(unnamedIssues: unnamed, namedFailures: 1, originalViewVisible: visible)
            XCTAssertEqual(BottomBarAttribution.outcome(after: step, canScrollFurther: true), .failed)
        }
    }

    private let band: ClosedRange<CGFloat> = 100...700

    /// Text that started inside the band stays in view while inside it, and leaves it under the
    /// navigation bar.
    func testTextInsideTheBandMustStayInside() {
        let text = { (minY: CGFloat) in CGRect(x: 0, y: minY, width: 100, height: 40) }
        XCTAssertTrue(BottomBarAttribution.isStillInView(text(104), firstMinY: 300, band: band))
        XCTAssertEqual(BottomBarAttribution.headroom(text(104), firstMinY: 300, band: band), 4)
        XCTAssertFalse(BottomBarAttribution.isStillInView(text(90), firstMinY: 300, band: band))
    }

    /// Text that started partly under the navigation bar is in view where it was, with no
    /// headroom, and not once it scrolls further under it.
    func testTextPartlyUnderTheNavigationBarCantScrollFurtherOut() {
        let text = { (minY: CGFloat) in CGRect(x: 0, y: minY, width: 100, height: 40) }
        XCTAssertTrue(BottomBarAttribution.isStillInView(text(80), firstMinY: 80, band: band))
        XCTAssertEqual(BottomBarAttribution.headroom(text(80), firstMinY: 80, band: band), 0)
        XCTAssertFalse(BottomBarAttribution.isStillInView(text(64), firstMinY: 80, band: band))
    }
}
