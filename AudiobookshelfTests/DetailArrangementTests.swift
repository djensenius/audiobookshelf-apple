import CoreGraphics
import Testing

@testable import Audiobookshelf

/// Item and episode detail across a fold (#85): split at a fold running down through them, from its reserved region and
/// the safe area, never the device model or pose.
@Suite struct DetailArrangementTests {
    /// The Duo's inner display in landscape, 951 points wide: the fold runs down its middle.
    private let width: CGFloat = 951
    private let bookFold = CGRect(x: 471, y: 0, width: 9, height: 669)

    private func resolve(supported: Bool = true, _ fold: DetailFold?) -> DetailArrangement {
        DetailArrangement.resolve(supportsArrangements: supported, fold: fold)
    }

    /// Before iOS 27.1 and on macOS the detail keeps its scroll view, even across a fold.
    @Test func withoutArrangementsTheDetailIsUnchanged() {
        let fold = DetailFold(width: width, divisions: [(bookFold, true)])
        #expect(fold != nil)
        #expect(resolve(supported: false, fold) == .scroll)
        #expect(resolve(supported: false, nil) == .scroll)
    }

    /// No fold, as on an iPad, an iPhone or the Duo's outer display, or none measured yet: as before.
    @Test func withoutAFoldTheDetailIsUnchanged() {
        #expect(DetailFold(width: width, divisions: []) == nil)
        #expect(resolve(nil) == .scroll)
    }

    /// Book pose: the fold runs down the middle, so the panes go either side of it.
    @Test func aFoldRunningDownSplits() throws {
        let fold = try #require(DetailFold(width: width, divisions: [(bookFold, true)]))
        #expect(fold.leadingWidth == 471)
        #expect(fold.trailingWidth == 471)
        #expect(resolve(fold) == .split)
    }

    /// Laptop pose: a fold running across a vertically scrolling detail doesn't split it, inactive or not.
    @Test func aFoldRunningAcrossIsIgnored() {
        let laptop = CGRect(x: 0, y: 471, width: 669, height: 9)
        let flat = CGRect(x: 0, y: 475.5, width: 669, height: 0)
        #expect(DetailFold(width: 669, divisions: [(laptop, true)]) == nil)
        #expect(DetailFold(width: 669, divisions: [(flat, false)]) == nil)
        // A fold running down still counts after one running across.
        #expect(DetailFold(width: width, divisions: [(laptop, true), (bookFold, true)])?.leadingWidth == 471)
    }

    /// Lying flat, the fold's region is inactive and has no width; the detail splits there all the same, so folding
    /// and unfolding doesn't rebuild it. The player, by contrast, ignores an inactive fold.
    @Test func anInactiveFoldStillSplits() throws {
        let flat = CGRect(x: 475.5, y: 0, width: 0, height: 669)
        let fold = try #require(DetailFold(width: width, divisions: [(flat, false)]))
        #expect(fold.leadingWidth == 475.5)
        #expect(fold.trailingWidth == 475.5)
        #expect(resolve(fold) == .split)
        #expect(PlayerFold(divisions: [(flat, false)]) == .flat)
    }

    /// A side narrower than the text column's minimum keeps the scroll view.
    @Test func aSideTooNarrowKeepsTheScroll() throws {
        #expect(DetailArrangement.minimumPaneWidth == 320)
        let narrowLeading = try #require(
            DetailFold(width: 631, divisions: [(CGRect(x: 155, y: 0, width: 9, height: 669), true)]))
        #expect(resolve(narrowLeading) == .scroll)
        let narrowTrailing = try #require(
            DetailFold(width: 631, divisions: [(CGRect(x: 320, y: 0, width: 9, height: 669), true)]))
        #expect(narrowTrailing.trailingWidth == 302)
        #expect(resolve(narrowTrailing) == .scroll)
        let justWideEnough = try #require(
            DetailFold(width: 649, divisions: [(CGRect(x: 320, y: 0, width: 9, height: 669), true)]))
        #expect(resolve(justWideEnough) == .split)
    }

    /// Each side's room ends at its own safe-area edge: a sidebar on the leading side, a vertical toolbar on the
    /// trailing side.
    @Test func eachSideStopsAtItsSafeArea() throws {
        let sidebar = try #require(DetailFold(width: width, leadingInset: 320, divisions: [(bookFold, true)]))
        #expect(sidebar.leadingWidth == 151)
        #expect(sidebar.trailingWidth == 471)
        let toolbar = try #require(DetailFold(width: width, trailingInset: 60, divisions: [(bookFold, true)]))
        #expect(toolbar.leadingWidth == 471)
        #expect(toolbar.trailingWidth == 411)
    }

    /// A fold outside the safe area, such as under a sidebar or past the edge, or unusable geometry: no fold.
    @Test func aFoldOutsideTheSafeAreaIsIgnored() {
        let underSidebar = CGRect(x: 150, y: 0, width: 9, height: 669)
        #expect(DetailFold(width: width, leadingInset: 320, divisions: [(underSidebar, true)]) == nil)
        for frame in [
            CGRect(x: -4.5, y: 0, width: 9, height: 669), CGRect(x: width - 4.5, y: 0, width: 9, height: 669),
            CGRect(x: 1_200, y: 0, width: 9, height: 669), .infinite, .null,
        ] {
            #expect(DetailFold(width: width, divisions: [(frame, true)]) == nil)
        }
        #expect(DetailFold(width: .nan, divisions: [(bookFold, true)]) == nil)
        #expect(DetailFold(width: .infinity, divisions: [(bookFold, true)]) == nil)
    }
}
