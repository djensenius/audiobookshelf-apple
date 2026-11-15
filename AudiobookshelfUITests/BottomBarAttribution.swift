import CoreGraphics

/// Whether a contrast issue with no element, deferred because content was under the bottom bar
/// (`KnownAuditIssue.isUnnamedContrastUnderBottomBar`), could be the other text on screen: the
/// test audits contrast in place, then after small steps toward clear of the bar while every text
/// that was on screen above the bar stays on screen. A failure on that text's own background
/// doesn't go away while it's in view, so if the issue goes away, it wasn't that text's, and the
/// content is then audited above the bar. If it persists until that text would have to leave the
/// view, or the content is clear of the bar, it can't be attributed, and the original failure
/// stands. #647
enum BottomBarAttribution {
    /// One contrast audit after a step.
    struct Step: Equatable {
        /// Contrast issues with no element.
        var unnamedIssues: Int
        /// Contrast issues, not filtered, on text that was on screen at first or under the bar.
        var namedFailures: Int
        /// Whether every text that was on screen above the bar at first still is
        /// (``isStillInView(_:firstMinY:band:)``).
        var originalViewVisible: Bool
    }

    /// What a step decides.
    enum Outcome: Equatable {
        /// Scroll another step and audit again.
        case undecided
        /// The issue went away with the original view still on screen: it wasn't that view's
        /// text's, and the test audits the content under the bar above it.
        case attributed
        /// Text that was on screen at first, or under the bar, failed by name.
        case failed
        /// The issue can't be put down to the content under the bar.
        case notAttributed(Reason)
    }

    /// Why an issue wasn't attributed.
    enum Reason: Equatable {
        /// Text that was on screen above the bar at first left the view.
        case viewLeft
        /// The issue persisted as far as the test could scroll with the original view on screen,
        /// or with the content clear of the bar.
        case persisted
    }

    /// The outcome of `step`, the latest; `canScrollFurther` is whether another step could move
    /// the content further toward clear of the bar with the original view on screen.
    static func outcome(after step: Step, canScrollFurther: Bool) -> Outcome {
        if step.namedFailures > 0 { return .failed }
        if !step.originalViewVisible { return .notAttributed(.viewLeft) }
        if step.unnamedIssues == 0 { return .attributed }
        return canScrollFurther ? .undecided : .notAttributed(.persisted)
    }

    /// Whether text that was in view with its top at `firstMinY` still is, now at `frame`, with
    /// `band` the space between the navigation bar and the bottom bar: it's not under the bottom
    /// bar, and its top is no higher than the band's top, or than it was if it started partly
    /// under the navigation bar, so partly visible text can't scroll further out of view.
    static func isStillInView(_ frame: CGRect, firstMinY: CGFloat, band: ClosedRange<CGFloat>) -> Bool {
        frame.minY >= min(band.lowerBound, firstMinY) - 0.5 && frame.maxY <= band.upperBound + 0.5
    }

    /// How far the text at `frame` can scroll up and stay in view (``isStillInView(_:firstMinY:band:)``):
    /// none for text that started partly under the navigation bar and hasn't moved.
    static func headroom(_ frame: CGRect, firstMinY: CGFloat, band: ClosedRange<CGFloat>) -> CGFloat {
        frame.minY - min(band.lowerBound, firstMinY)
    }

    /// Whether text at `frame` is under the bottom bar: on screen in `region`, from the bottom
    /// bar's top down to the window's bottom edge, which takes in the bars, the gap below a
    /// floating mini player (the iPhone Duo's) and the home indicator's edge. More than half a
    /// point into it, so text is either under the bar or still in view (``isStillInView(_:firstMinY:band:)``).
    /// An empty region, without a bottom bar, has nothing under it. #650
    static func isUnderBottomBar(_ frame: CGRect, region: CGRect) -> Bool {
        region.height > 0 && !frame.isEmpty && frame.maxY > region.minY + 0.5 && frame.minY < region.maxY
            && frame.maxX > region.minX && frame.minX < region.maxX
    }

    /// Whether text at `frame` has scrolled up under the navigation bar, whose bottom is
    /// `bandTop`, in part: the audit measures it through that bar's glass, as it does text under
    /// the bottom bar. #650
    static func isUnderNavigationBar(_ frame: CGRect, bandTop: CGFloat) -> Bool {
        frame.minY < bandTop - 0.5
    }

    /// Whether text at `frame` is wholly between the bars, in `band` (the navigation bar's bottom
    /// to the bottom bar's top): under neither, with their half-point tolerances. A deferred
    /// issue's text must be audited so at least once. #650
    static func isWhollyInBand(_ frame: CGRect, band: ClosedRange<CGFloat>) -> Bool {
        !frame.isEmpty && !isUnderNavigationBar(frame, bandTop: band.lowerBound)
            && frame.maxY <= band.upperBound + 0.5
    }
}
