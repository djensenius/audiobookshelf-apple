import CoreGraphics
import Foundation

/// The pages shown together: one page, or two side by side (ADR 0008, decision 7).
public struct ComicSpread: Sendable, Hashable {
    /// 1-based, ascending; one or two pages.
    public let pages: [Int]

    public init(_ pages: [Int]) {
        self.pages = pages
    }

    /// The lower page, which is the spread's `ebookLocation`.
    public var lower: Int { pages[0] }

    /// The pages from left to right: right to left puts the lower page on the right.
    public func displayOrder(rightToLeft: Bool) -> [Int] {
        rightToLeft ? pages.reversed() : pages
    }
}

/// The comic reader's layout rules (ADR 0008, decision 7), without SwiftUI so `swift test` covers
/// them.
public enum ComicReaderLayout {
    /// The arrow key pressed, for keyboard page turns.
    public enum Arrow: Sendable, Hashable {
        case left
        case right
    }

    /// The spreads of a comic of `pageCount` pages.
    ///
    /// A single-page layout shows each page alone. A two-page one shows page 1 (the cover) alone,
    /// then pairs (2, 3), (4, 5) and so on. A page in `alone` (marked in `ComicInfo.xml`, or a
    /// landscape image) and a final odd page are shown alone too, and pairing restarts after them.
    public static func spreads(pageCount: Int, twoUp: Bool, alone: Set<Int> = []) -> [ComicSpread] {
        guard pageCount > 0 else { return [] }
        guard twoUp else { return (1...pageCount).map { ComicSpread([$0]) } }
        var spreads: [ComicSpread] = []
        var page = 1
        while page <= pageCount {
            if page == 1 || page == pageCount || alone.contains(page) || alone.contains(page + 1) {
                spreads.append(ComicSpread([page]))
                page += 1
            } else {
                spreads.append(ComicSpread([page, page + 1]))
                page += 2
            }
        }
        return spreads
    }

    /// The index of the spread showing `page`; the first spread when no spread has it.
    public static func spreadIndex(containing page: Int, in spreads: [ComicSpread]) -> Int {
        spreads.firstIndex { $0.pages.contains(page) } ?? 0
    }

    /// The pages shown alone in a spread because `ComicInfo.xml` marks them: its `<Page Image>`
    /// indexes are 0-based, so image `n` is page `n + 1`. Indexes that aren't a page (negative, or
    /// too large to add 1 to) are ignored.
    public static func markedAlone(_ info: ComicInfo?) -> Set<Int> {
        Set(
            (info?.singlePageImages ?? []).compactMap { image in
                let (page, overflow) = image.addingReportingOverflow(1)
                return image >= 0 && !overflow ? page : nil
            })
    }

    /// The pages kept decoded beyond the visible ones in each direction, so a long comic doesn't
    /// hold every page it has shown: the spreads either side, and one more for a swipe.
    public static let decodeMargin = 4

    /// Whether `page` is visible or within ``decodeMargin`` of the visible pages, so it keeps its
    /// decoded image.
    public static func keepsDecoded(_ page: Int, visible: ClosedRange<Int>) -> Bool {
        let (low, lowOverflow) = visible.lowerBound.subtractingReportingOverflow(decodeMargin)
        let (high, highOverflow) = visible.upperBound.addingReportingOverflow(decodeMargin)
        return (lowOverflow ? Int.min : low)...(highOverflow ? Int.max : high) ~= page
    }

    /// Whether an image is landscape, which usually means a pre-joined spread.
    public static func isLandscape(_ size: CGSize) -> Bool {
        size.width > size.height
    }

    /// Maps between a spread's reading index and its position from the left, in either direction:
    /// right to left shows the first spread at the right end.
    public static func displayIndex(_ index: Int, count: Int, rightToLeft: Bool) -> Int {
        rightToLeft ? count - 1 - index : index
    }

    /// The reading step an arrow key makes: the right arrow goes forward from left to right, the
    /// left arrow from right to left.
    public static func step(for arrow: Arrow, rightToLeft: Bool) -> Int {
        (arrow == .right) != rightToLeft ? 1 : -1
    }

    /// The zoom a pinch may reach.
    public static let zoomRange: ClosedRange<CGFloat> = 1...5

    /// The size of a spread's pages aspect-fitted side by side in `viewport`, `gap` apart: each
    /// page fits half the width (or all of it alone). A page not yet decoded fills its half.
    public static func fittedSize(of pages: [CGSize?], gap: CGFloat, in viewport: CGSize) -> CGSize {
        guard !pages.isEmpty else { return viewport }
        let gaps = gap * CGFloat(pages.count - 1)
        let cell = CGSize(width: max(viewport.width - gaps, 0) / CGFloat(pages.count), height: viewport.height)
        let fitted = pages.map { page -> CGSize in
            guard let page, page.width > 0, page.height > 0 else { return cell }
            let ratio = min(cell.width / page.width, cell.height / page.height)
            return CGSize(width: page.width * ratio, height: page.height * ratio)
        }
        return CGSize(width: fitted.reduce(gaps) { $0 + $1.width }, height: fitted.map(\.height).max() ?? 0)
    }

    /// The pan offset of `content`, centred in `viewport` and zoomed by `scale`, kept so the
    /// content's edges never come inside the viewport: each axis pans only as far as the zoomed
    /// content overflows it. No offset at `1×`.
    public static func clampedOffset(
        _ offset: CGSize, scale: CGFloat, content: CGSize, viewport: CGSize
    ) -> CGSize {
        let scale = min(max(scale, zoomRange.lowerBound), zoomRange.upperBound)
        let limit = CGSize(
            width: max(content.width * scale - viewport.width, 0) / 2,
            height: max(content.height * scale - viewport.height, 0) / 2)
        return CGSize(
            width: min(max(offset.width, -limit.width), limit.width),
            height: min(max(offset.height, -limit.height), limit.height))
    }
}
