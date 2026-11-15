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

    /// The iPhone Duo's outer display: the mini player floats from y 608 of 678, with a gap below
    /// it. A row cut off by the window's bottom edge, below the mini player, is under the bar, as
    /// is a row reaching into the mini player; one ending at its top is in view, and one wholly
    /// below the window isn't on screen. #650
    func testTextAnywhereFromTheBottomBarToTheWindowsEdgeIsUnderIt() {
        let region = CGRect(x: 0, y: 608, width: 466, height: 70)
        let text = { (minY: CGFloat) in CGRect(x: 16, y: minY, width: 300, height: 40) }
        XCTAssertTrue(BottomBarAttribution.isUnderBottomBar(text(660), region: region))
        XCTAssertTrue(BottomBarAttribution.isUnderBottomBar(text(580), region: region))
        XCTAssertFalse(BottomBarAttribution.isUnderBottomBar(text(568.25), region: region))
        XCTAssertFalse(BottomBarAttribution.isUnderBottomBar(text(700), region: region))
        XCTAssertTrue(BottomBarAttribution.isStillInView(text(568.25), firstMinY: 568.25, band: 100...608))
    }

    /// Without a bottom bar the region is empty, so nothing is under it.
    func testNothingIsUnderAMissingBottomBar() {
        let region = CGRect(x: 0, y: 678, width: 466, height: 0)
        XCTAssertFalse(
            BottomBarAttribution.isUnderBottomBar(CGRect(x: 16, y: 650, width: 300, height: 40), region: region))
    }

    /// Settings at the default size, scrolled up half the band: "Playback Settings" from y 88,
    /// under a navigation bar ending at y 133, is under it; a row starting at its bottom isn't.
    func testTextScrolledUpUnderTheNavigationBarIsUnderIt() {
        let text = { (minY: CGFloat) in CGRect(x: 16, y: minY, width: 300, height: 24) }
        XCTAssertTrue(BottomBarAttribution.isUnderNavigationBar(text(88), bandTop: 133))
        XCTAssertFalse(BottomBarAttribution.isUnderNavigationBar(text(132.75), bandTop: 133))
    }

    /// Text taller than half the band can go from under the bottom bar to under the navigation bar
    /// in one half-band step (300 points here), so it's never wholly between them; a step that
    /// lands it in the band covers it.
    func testTallTextCanSkipTheBandInOneHalfBandStep() {
        let text = { (minY: CGFloat) in CGRect(x: 16, y: minY, width: 300, height: 400) }
        XCTAssertFalse(BottomBarAttribution.isWhollyInBand(text(350), band: band))
        XCTAssertFalse(BottomBarAttribution.isWhollyInBand(text(350 - 300), band: band))
        XCTAssertTrue(BottomBarAttribution.isWhollyInBand(text(200), band: band))
    }
}
