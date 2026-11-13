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

    /// The widest a vertical-scroll row may be for its height. A page wider than this is shown
    /// letterboxed in a taller row, so very short pages can't put thousands of rows (and their
    /// decodes) on screen at once.
    public static let maxScrollRowAspect: CGFloat = 4

    /// The aspect ratio of `size`'s row in vertical scroll: its own, unless it is wider than
    /// ``maxScrollRowAspect`` or has no area.
    public static func scrollRowAspect(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxScrollRowAspect, height: 1) }
        return CGSize(width: size.width, height: max(size.height, size.width / maxScrollRowAspect))
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

    /// The zoom a double-tap goes to from `1×`.
    public static let doubleTapScale: CGFloat = 2

    /// A double-tap's zoom and pan: unzoomed goes to ``doubleTapScale``, zoomed goes back to `1×`.
    /// The pan is the centred one clamped for the new zoom, so an off-centre spread that fits
    /// shows all of itself.
    public static func doubleTapTarget(
        from scale: CGFloat, content: CGRect, viewport: CGSize
    ) -> (scale: CGFloat, offset: CGSize) {
        let target = scale > 1 ? 1 : doubleTapScale
        return (target, clampedOffset(.zero, scale: target, content: content, viewport: viewport))
    }

    /// Where a spread's pages land aspect-fitted side by side in `viewport`, `gap` apart, in
    /// display order (left to right): each page fits its half of the width and sits against the
    /// gutter, so pages of unequal widths make an off-centre spread. A page alone is centred, and
    /// a page not yet decoded fills its half.
    public static func fittedRect(of pages: [CGSize?], gap: CGFloat, in viewport: CGSize) -> CGRect {
        guard !pages.isEmpty else { return CGRect(origin: .zero, size: viewport) }
        let gaps = gap * CGFloat(pages.count - 1)
        let cell = CGSize(width: max(viewport.width - gaps, 0) / CGFloat(pages.count), height: viewport.height)
        let frames = pages.enumerated().map { index, page -> CGRect in
            var size = cell
            if let page, page.width > 0, page.height > 0 {
                let ratio = min(cell.width / page.width, cell.height / page.height)
                size = CGSize(width: page.width * ratio, height: page.height * ratio)
            }
            let cellX = CGFloat(index) * (cell.width + gap)
            let x =
                if pages.count == 1 { cellX + (cell.width - size.width) / 2 } else if index == 0 {
                    cellX + cell.width - size.width
                } else { cellX }
            return CGRect(x: x, y: (viewport.height - size.height) / 2, width: size.width, height: size.height)
        }
        return frames.dropFirst().reduce(frames[0]) { $0.union($1) }
    }

    /// The pan offset of `content` (a rectangle in `viewport`) zoomed by `scale` about the
    /// viewport's centre. On each axis where the zoomed content covers the viewport, it pans only
    /// until its edge reaches the viewport's; where it doesn't, it doesn't pan, and sits at the offset
    /// nearest zero that shows all of it. No offset at `1×`.
    public static func clampedOffset(
        _ offset: CGSize, scale: CGFloat, content: CGRect, viewport: CGSize
    ) -> CGSize {
        let scale = min(max(scale, zoomRange.lowerBound), zoomRange.upperBound)
        func axis(_ offset: CGFloat, _ low: CGFloat, _ high: CGFloat, _ length: CGFloat) -> CGFloat {
            let centre = length / 2
            let (scaledLow, scaledHigh) = (centre + (low - centre) * scale, centre + (high - centre) * scale)
            // The offsets that bring each edge to the viewport's edge.
            let (lowest, highest) = (length - scaledHigh, -scaledLow)
            return lowest <= highest ? min(max(offset, lowest), highest) : min(max(0, highest), lowest)
        }
        return CGSize(
            width: axis(offset.width, content.minX, content.maxX, viewport.width),
            height: axis(offset.height, content.minY, content.maxY, viewport.height))
    }
}
