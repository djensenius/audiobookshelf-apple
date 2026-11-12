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
        #expect(ComicReaderLayout.clampedOffset(CGSize(width: 30, height: -40), scale: 1, size: size) == .zero)
        #expect(
            ComicReaderLayout.clampedOffset(CGSize(width: 80, height: -300), scale: 2, size: size)
                == CGSize(width: 50, height: -100))
        #expect(
            ComicReaderLayout.clampedOffset(CGSize(width: 10, height: 20), scale: 2, size: size)
                == CGSize(width: 10, height: 20))
        // Past the zoom range counts as its end.
        #expect(
            ComicReaderLayout.clampedOffset(CGSize(width: 1000, height: 0), scale: 50, size: size)
                == CGSize(width: 200, height: 0))
    }
}
