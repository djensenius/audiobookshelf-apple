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
            ComicReaderLayout.clampedOffset(offset, scale: scale, content: size, viewport: size)
        }
        #expect(clamp(CGSize(width: 30, height: -40), 1) == .zero)
        #expect(clamp(CGSize(width: 80, height: -300), 2) == CGSize(width: 50, height: -100))
        #expect(clamp(CGSize(width: 10, height: 20), 2) == CGSize(width: 10, height: 20))
        // Past the zoom range counts as its end.
        #expect(clamp(CGSize(width: 1000, height: 0), 50) == CGSize(width: 200, height: 0))
    }

    @Test func panningStopsAtTheFittedPageNotTheViewport() {
        let viewport = CGSize(width: 1200, height: 800)
        let cover = ComicReaderLayout.fittedSize(of: [CGSize(width: 600, height: 800)], gap: 0, in: viewport)
        #expect(cover == CGSize(width: 600, height: 800))
        // At 2× the cover is exactly as wide as the viewport, so it can't pan sideways.
        #expect(
            ComicReaderLayout.clampedOffset(
                CGSize(width: 600, height: 600), scale: 2, content: cover, viewport: viewport)
                == CGSize(width: 0, height: 400))
        #expect(
            ComicReaderLayout.clampedOffset(CGSize(width: 900, height: 0), scale: 3, content: cover, viewport: viewport)
                == CGSize(width: 300, height: 0))
    }

    @Test func aSpreadFitsItsPagesSideBySide() {
        let viewport = CGSize(width: 1000, height: 800)
        let portrait = CGSize(width: 400, height: 800)
        #expect(
            ComicReaderLayout.fittedSize(of: [portrait, portrait], gap: 20, in: viewport)
                == CGSize(width: 820, height: 800))
        // Pages too wide for their half fit its width; an undecoded page fills its half.
        #expect(
            ComicReaderLayout.fittedSize(of: [CGSize(width: 980, height: 490), nil], gap: 20, in: viewport)
                == CGSize(width: 1000, height: 800))
        #expect(
            ComicReaderLayout.fittedSize(of: [CGSize(width: 500, height: 250)], gap: 0, in: viewport)
                == CGSize(width: 1000, height: 500))
        #expect(ComicReaderLayout.fittedSize(of: [], gap: 0, in: viewport) == viewport)
    }
}
