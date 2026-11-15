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
        /// Whether every text that was on screen above the bar at first still is, below the
        /// navigation bar and above the bottom bar.
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
}
