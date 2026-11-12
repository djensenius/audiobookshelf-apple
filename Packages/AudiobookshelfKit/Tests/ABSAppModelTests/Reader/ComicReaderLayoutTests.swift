import CoreGraphics
import Foundation
import Testing

@testable import ABSAppModel

@Suite struct ComicReaderLayoutTests {
    private func pages(_ spreads: [ComicSpread]) -> [[Int]] {
        spreads.map(\.pages)
    }

    @Test func theCoverIsAloneThenPagesPair() {
        #expect(pages(ComicReaderLayout.spreads(pageCount: 5, twoUp: true)) == [[1], [2, 3], [4, 5]])
        #expect(pages(ComicReaderLayout.spreads(pageCount: 6, twoUp: true)) == [[1], [2, 3], [4, 5], [6]])
        #expect(pages(ComicReaderLayout.spreads(pageCount: 1, twoUp: true)) == [[1]])
        #expect(ComicReaderLayout.spreads(pageCount: 0, twoUp: true).isEmpty)
    }

    @Test func aSinglePageLayoutShowsEveryPageAlone() {
        #expect(pages(ComicReaderLayout.spreads(pageCount: 4, twoUp: false, alone: [3])) == [[1], [2], [3], [4]])
    }

    @Test func pairingRestartsAfterAPageShownAlone() {
        #expect(
            pages(ComicReaderLayout.spreads(pageCount: 9, twoUp: true, alone: [4]))
                == [[1], [2, 3], [4], [5, 6], [7, 8], [9]])
        // A page before one shown alone has no partner.
        #expect(
            pages(ComicReaderLayout.spreads(pageCount: 7, twoUp: true, alone: [3]))
                == [[1], [2], [3], [4, 5], [6, 7]])
    }

    @Test func comicInfoImagesAreZeroBased() {
        #expect(ComicReaderLayout.markedAlone(ComicInfo(singlePageImages: [0, 5])) == [1, 6])
        #expect(ComicReaderLayout.markedAlone(nil).isEmpty)
    }

    @Test func comicInfoImagesThatArentPagesAreIgnored() {
        let info = ComicInfo(singlePageImages: [Int.max, -1, Int.min, 2])
        #expect(ComicReaderLayout.markedAlone(info) == [3])
    }

    @Test func visiblePagesAndAMarginStayDecoded() {
        let kept = (1...20).filter { ComicReaderLayout.keepsDecoded($0, visible: 10...10) }
        #expect(kept == Array(6...14))
        // Vertical scroll: every visible page, however many, plus the margin below the last.
        let tall = (1...20).filter { ComicReaderLayout.keepsDecoded($0, visible: 1...8) }
        #expect(tall == Array(1...12))
        #expect(!ComicReaderLayout.keepsDecoded(Int.min, visible: 10...10))
        #expect(ComicReaderLayout.keepsDecoded(Int.max, visible: (Int.max - 1)...Int.max))
        #expect(ComicReaderLayout.keepsDecoded(Int.min, visible: Int.min...Int.min))
    }

    @Test func onlyWiderThanTallIsLandscape() {
        #expect(ComicReaderLayout.isLandscape(CGSize(width: 200, height: 100)))
        #expect(!ComicReaderLayout.isLandscape(CGSize(width: 100, height: 100)))
        #expect(!ComicReaderLayout.isLandscape(CGSize(width: 100, height: 200)))
    }

    @Test func spreadIndexFindsEitherPage() {
        let spreads = ComicReaderLayout.spreads(pageCount: 5, twoUp: true)
        #expect(ComicReaderLayout.spreadIndex(containing: 3, in: spreads) == 1)
        #expect(ComicReaderLayout.spreadIndex(containing: 4, in: spreads) == 2)
        #expect(ComicReaderLayout.spreadIndex(containing: 9, in: spreads) == 0)
    }

    @Test func rightToLeftPutsTheLowerPageOnTheRight() {
        let spread = ComicSpread([2, 3])
        #expect(spread.displayOrder(rightToLeft: false) == [2, 3])
        #expect(spread.displayOrder(rightToLeft: true) == [3, 2])
        #expect(spread.lower == 2)
    }

    @Test func rightToLeftShowsTheFirstSpreadAtTheRightEnd() {
        #expect((0..<4).map { ComicReaderLayout.displayIndex($0, count: 4, rightToLeft: false) } == [0, 1, 2, 3])
        #expect((0..<4).map { ComicReaderLayout.displayIndex($0, count: 4, rightToLeft: true) } == [3, 2, 1, 0])
        // The mapping is its own inverse.
        for index in 0..<4 {
            let shown = ComicReaderLayout.displayIndex(index, count: 4, rightToLeft: true)
            #expect(ComicReaderLayout.displayIndex(shown, count: 4, rightToLeft: true) == index)
        }
    }

    @Test func arrowKeysFollowTheReadingDirection() {
        #expect(ComicReaderLayout.step(for: .right, rightToLeft: false) == 1)
        #expect(ComicReaderLayout.step(for: .left, rightToLeft: false) == -1)
        #expect(ComicReaderLayout.step(for: .right, rightToLeft: true) == -1)
        #expect(ComicReaderLayout.step(for: .left, rightToLeft: true) == 1)
    }

    @Test func aZoomedPageCanPanOnlyToItsEdges() {
        let size = CGSize(width: 100, height: 200)
        func clamp(_ offset: CGSize, _ scale: CGFloat) -> CGSize {
            ComicReaderLayout.clampedOffset(
                offset, scale: scale, content: CGRect(origin: .zero, size: size), viewport: size)
        }
        #expect(clamp(CGSize(width: 30, height: -40), 1) == .zero)
        #expect(clamp(CGSize(width: 80, height: -300), 2) == CGSize(width: 50, height: -100))
        #expect(clamp(CGSize(width: 10, height: 20), 2) == CGSize(width: 10, height: 20))
        // Past the zoom range counts as its end.
        #expect(clamp(CGSize(width: 1000, height: 0), 50) == CGSize(width: 200, height: 0))
    }

    @Test func panningStopsAtTheFittedPageNotTheViewport() {
        let viewport = CGSize(width: 1200, height: 800)
        let cover = ComicReaderLayout.fittedRect(of: [CGSize(width: 600, height: 800)], gap: 0, in: viewport)
        #expect(cover == CGRect(x: 300, y: 0, width: 600, height: 800))
        // At 2× the cover is exactly as wide as the viewport, so it can't pan sideways.
        #expect(
            ComicReaderLayout.clampedOffset(
                CGSize(width: 600, height: 600), scale: 2, content: cover, viewport: viewport)
                == CGSize(width: 0, height: 400))
        #expect(
            ComicReaderLayout.clampedOffset(CGSize(width: 900, height: 0), scale: 3, content: cover, viewport: viewport)
                == CGSize(width: 300, height: 0))
    }

    @Test func anUnevenSpreadPansToItsOwnEdgesInEitherDirection() {
        let viewport = CGSize(width: 1000, height: 800)
        let (narrow, wide) = (CGSize(width: 300, height: 800), CGSize(width: 500, height: 800))
        func clamp(_ pages: [CGSize], _ x: CGFloat, _ scale: CGFloat = 2) -> CGFloat {
            let content = ComicReaderLayout.fittedRect(of: pages, gap: 0, in: viewport)
            return ComicReaderLayout.clampedOffset(
                CGSize(width: x, height: 0), scale: scale, content: content, viewport: viewport
            ).width
        }
        // Left to right: the narrow page sits against the gutter, so the spread spans 200...1000.
        #expect(ComicReaderLayout.fittedRect(of: [narrow, wide], gap: 0, in: viewport).minX == 200)
        #expect(clamp([narrow, wide], 300) == 100)
        #expect(clamp([narrow, wide], -800) == -500)
        // Right to left shows the wide page first: 0...800.
        #expect(ComicReaderLayout.fittedRect(of: [wide, narrow], gap: 0, in: viewport).maxX == 800)
        #expect(clamp([wide, narrow], 600) == 500)
        #expect(clamp([wide, narrow], -300) == -100)
        // Unzoomed it doesn't move; zoomed but still narrower, it shifts just enough to show it all.
        #expect(clamp([narrow, wide], 300, 1) == 0)
        #expect(clamp([narrow, wide], 300, 1.125) == -62.5)
    }

    @Test func aDoubleTapShowsAWholeOffCentreSpreadThatFits() {
        let viewport = CGSize(width: 1000, height: 800)
        let content = ComicReaderLayout.fittedRect(
            of: [CGSize(width: 100, height: 800), CGSize(width: 300, height: 800)], gap: 0, in: viewport)
        #expect(content == CGRect(x: 400, y: 0, width: 400, height: 800))
        let zoomIn = ComicReaderLayout.doubleTapTarget(from: 1, content: content, viewport: viewport)
        #expect(zoomIn.scale == 2)
        #expect(zoomIn.offset == CGSize(width: -100, height: 0))
        // The zoomed spread, 300...1100 about the centre, moves to 200...1000: all of it on screen.
        let left = viewport.width / 2 + (content.minX - viewport.width / 2) * zoomIn.scale + zoomIn.offset.width
        let right = viewport.width / 2 + (content.maxX - viewport.width / 2) * zoomIn.scale + zoomIn.offset.width
        #expect(left >= 0 && right <= viewport.width)
        let zoomOut = ComicReaderLayout.doubleTapTarget(from: 2, content: content, viewport: viewport)
        #expect(zoomOut.scale == 1)
        #expect(zoomOut.offset == .zero)
    }

    @Test func aSpreadFitsItsPagesSideBySide() {
        let viewport = CGSize(width: 1000, height: 800)
        let portrait = CGSize(width: 400, height: 800)
        #expect(
            ComicReaderLayout.fittedRect(of: [portrait, portrait], gap: 20, in: viewport)
                == CGRect(x: 90, y: 0, width: 820, height: 800))
        // Pages too wide for their half fit its width; an undecoded page fills its half.
        #expect(
            ComicReaderLayout.fittedRect(of: [CGSize(width: 980, height: 490), nil], gap: 20, in: viewport)
                == CGRect(origin: .zero, size: viewport))
        #expect(
            ComicReaderLayout.fittedRect(of: [CGSize(width: 500, height: 250)], gap: 0, in: viewport)
                == CGRect(x: 0, y: 150, width: 1000, height: 500))
        #expect(ComicReaderLayout.fittedRect(of: [], gap: 0, in: viewport) == CGRect(origin: .zero, size: viewport))
    }
}
