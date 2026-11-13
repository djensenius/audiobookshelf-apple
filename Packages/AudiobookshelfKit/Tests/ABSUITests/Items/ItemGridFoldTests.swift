import CoreGraphics
import SwiftUI
import Testing

@testable import ABSUI

/// An ``ItemGrid``'s columns around a fold (#85): the same number on each side, so the count is even, with a gap over
/// the fold so no card straddles it; without a fold running down through the grid, its adaptive columns.
@Suite struct ItemGridFoldTests {
    /// A fold running down a display 1,000 points tall, from `minX` to `maxX`.
    private func division(_ minX: CGFloat, _ maxX: CGFloat, isActive: Bool = true) -> (frame: CGRect, isActive: Bool) {
        (CGRect(x: minX, y: 0, width: maxX - minX, height: 1_000), isActive)
    }

    private func plan(
        width: CGFloat, _ divisions: [(frame: CGRect, isActive: Bool)], size: DynamicTypeSize = .large
    ) -> ItemGridFoldLayout? {
        ItemGridFold(width: width, divisions: divisions).flatMap {
            ItemGridMetrics.foldLayout($0, dynamicTypeSize: size)
        }
    }

    /// The leading inset, the columns, the spacing between them and the trailing inset, which together fill the grid.
    private func filledWidth(_ layout: ItemGridFoldLayout) -> CGFloat {
        let spacings = (0..<max(0, layout.columnCount - 1)).map { layout.spacing(after: $0) }.reduce(0, +)
        return layout.leadingInset + CGFloat(layout.columnCount) * layout.columnWidth + spacings
            + layout.trailingInset
    }

    /// Where the columns before the fold end and those after it start, from the grid's leading edge.
    private func foldGap(_ layout: ItemGridFoldLayout) -> (start: CGFloat, end: CGFloat) {
        let leading = CGFloat(layout.leadingColumns)
        let start = layout.leadingInset + leading * layout.columnWidth + max(0, leading - 1) * layout.spacing
        return (start, start + (layout.leadingColumns > 0 ? layout.foldSpacing : 0))
    }

    /// Whether every card lies wholly before the fold, from `minX`, or after it, to `maxX`.
    private func cardsClear(_ layout: ItemGridFoldLayout, ofFoldFrom minX: CGFloat, to maxX: CGFloat) -> Bool {
        var start = layout.leadingInset
        return (0..<layout.columnCount).allSatisfy { index in
            defer { start += layout.columnWidth + layout.spacing(after: index) }
            return start + layout.columnWidth <= minX + 0.001 || start >= maxX - 0.001
        }
    }

    @Test func withoutAFoldTheGridKeepsItsAdaptiveColumns() {
        #expect(ItemGridFold(width: 800, divisions: []) == nil)
        // Laptop pose: the fold runs across, which a vertically scrolling grid doesn't mind.
        #expect(ItemGridFold(width: 800, divisions: [(CGRect(x: 0, y: 400, width: 800, height: 20), true)]) == nil)
        // A fold beside the grid (a split view's other column) doesn't touch it.
        #expect(ItemGridFold(width: 800, divisions: [division(-30, -10), division(810, 830)]) == nil)
        #expect(ItemGridFold(width: 800, divisions: [(.zero, true)]) == nil)
        #expect(ItemGridFold(width: .nan, divisions: [division(390, 410)]) == nil)
    }

    /// Book pose on a width the adaptive grid fills with an odd 5 columns: 2 on each side instead, with the grid's
    /// padding outside and a gap of the fold reservation over the fold, which is narrower.
    @Test func aVerticalFoldSplitsAnOddCountEvenly() throws {
        #expect(ItemGridMetrics.columnCount(width: 800, dynamicTypeSize: .large) == 5)
        let fold = try #require(ItemGridFold(width: 800, divisions: [division(390, 410)]))
        #expect(fold == ItemGridFold(width: 800, divisions: [(CGRect(x: 390, y: -200, width: 20, height: 900), true)]))
        let layout = try #require(ItemGridMetrics.foldLayout(fold, dynamicTypeSize: .large))
        #expect(
            layout
                == ItemGridFoldLayout(
                    leadingColumns: 2, trailingColumns: 2, columnWidth: 176, spacing: 16, foldSpacing: 32,
                    leadingInset: 16, trailingInset: 16))
        #expect([0, 1, 2].map(layout.spacing(after:)) == [16, 32, 16])
        #expect(foldGap(layout) == (384, 416))
        #expect(cardsClear(layout, ofFoldFrom: 390, to: 410))
    }

    /// Lying flat the fold's region is inactive and has no width; the columns still split around it, just as once it
    /// folds, so they don't move.
    @Test func anInactiveFoldStillSplitsTheColumns() throws {
        let flat = try #require(plan(width: 800, [division(400, 400, isActive: false)]))
        #expect(
            flat
                == ItemGridFoldLayout(
                    leadingColumns: 2, trailingColumns: 2, columnWidth: 176, spacing: 16, foldSpacing: 32,
                    leadingInset: 16, trailingInset: 16))
        #expect(foldGap(flat) == (384, 416))
        #expect(try #require(plan(width: 800, [division(390, 410)])) == flat)
    }

    /// A grid off the fold's centre (a vertical bar on one side) fits the narrower side's columns on both, of one
    /// width; the wider side's extra space goes outside them.
    @Test func theNarrowerSideSetsTheColumns() throws {
        let layout = try #require(plan(width: 700, [division(300, 320)]))
        #expect(
            layout
                == ItemGridFoldLayout(
                    leadingColumns: 1, trailingColumns: 1, columnWidth: 278, spacing: 16, foldSpacing: 32,
                    leadingInset: 16, trailingInset: 96))
        #expect(foldGap(layout) == (294, 326))
        #expect(filledWidth(layout) == 700)
    }

    /// A side too narrow for a card stays empty and the other side's columns keep clear of the fold.
    @Test func aSideTooNarrowForACardIsLeftEmpty() throws {
        let trailing = try #require(plan(width: 600, [division(100, 120)]))
        #expect(
            trailing
                == ItemGridFoldLayout(
                    leadingColumns: 0, trailingColumns: 3, columnWidth: 142, spacing: 16, foldSpacing: 32,
                    leadingInset: 126, trailingInset: 16))
        #expect([0, 1].map(trailing.spacing(after:)) == [16, 16])

        let leading = try #require(plan(width: 600, [division(480, 500)]))
        #expect(
            leading
                == ItemGridFoldLayout(
                    leadingColumns: 3, trailingColumns: 0, columnWidth: 142, spacing: 16, foldSpacing: 32,
                    leadingInset: 16, trailingInset: 126))
        #expect([0, 1].map(leading.spacing(after:)) == [16, 16])
        #expect(filledWidth(trailing) == 600 && filledWidth(leading) == 600)
        #expect(cardsClear(trailing, ofFoldFrom: 100, to: 120) && cardsClear(leading, ofFoldFrom: 480, to: 500))
    }

    /// Neither side fits a card of the minimum width, as at accessibility text sizes on a narrow grid: a narrower
    /// card on each side, clear of the fold, rather than adaptive ones across it.
    @Test func whenNeitherSideFitsACardNarrowerOnesStayEachSideOfTheFold() throws {
        let accessible = try #require(plan(width: 460, [division(220, 240)], size: .accessibility3))
        #expect(
            accessible
                == ItemGridFoldLayout(
                    leadingColumns: 1, trailingColumns: 1, columnWidth: 198, spacing: 16, foldSpacing: 32,
                    leadingInset: 16, trailingInset: 16))
        #expect(cardsClear(accessible, ofFoldFrom: 220, to: 240))

        let narrow = try #require(plan(width: 200, [division(95, 105)]))
        #expect(
            narrow
                == ItemGridFoldLayout(
                    leadingColumns: 1, trailingColumns: 1, columnWidth: 68, spacing: 16, foldSpacing: 32,
                    leadingInset: 16, trailingInset: 16))
        #expect(cardsClear(narrow, ofFoldFrom: 95, to: 105))
        #expect(filledWidth(accessible) == 460 && filledWidth(narrow) == 200)
    }

    /// Neither side fits a card of the minimum width and one has room for less than half of one: a single narrower
    /// card on the other side, clear of the fold. Only with no room either side does the grid keep its adaptive
    /// columns.
    @Test func whenNeitherSideFitsACardASideWithLittleRoomIsLeftEmpty() throws {
        let trailing = try #require(plan(width: 200, [division(40, 40, isActive: false)]))
        #expect(
            trailing
                == ItemGridFoldLayout(
                    leadingColumns: 0, trailingColumns: 1, columnWidth: 128, spacing: 16, foldSpacing: 32,
                    leadingInset: 56, trailingInset: 16))
        #expect(cardsClear(trailing, ofFoldFrom: 40, to: 40))

        let leading = try #require(plan(width: 200, [division(160, 160, isActive: false)]))
        #expect(
            leading
                == ItemGridFoldLayout(
                    leadingColumns: 1, trailingColumns: 0, columnWidth: 128, spacing: 16, foldSpacing: 32,
                    leadingInset: 16, trailingInset: 56))
        #expect(cardsClear(leading, ofFoldFrom: 160, to: 160))
        #expect(filledWidth(trailing) == 200 && filledWidth(leading) == 200)

        #expect(plan(width: 40, [division(20, 20)]) == nil)
    }

    /// Any width, odd or fractional, with the fold in the middle, at any text size: as many columns flat as folded
    /// (at 641.25 points and the large size, a fold 21.5 points wide once took a column from each side).
    @Test func theColumnCountIsTheSameFlatOrFolded() throws {
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
            let minimum = ItemGridMetrics.minimumCellWidth(for: size)
            for width in stride(from: CGFloat(2 * minimum + 64), through: 1_400.5, by: 7.25) {
                let counts = try [CGFloat(0), 21.5, 40].map { foldWidth -> [Int] in
                    let minX = (width - foldWidth) / 2
                    let layout = try #require(
                        plan(width: width, [division(minX, minX + foldWidth, isActive: foldWidth > 0)], size: size))
                    return [layout.leadingColumns, layout.trailingColumns]
                }
                #expect(Set(counts).count == 1, "\(width) points at \(size): \(counts)")
            }
        }
    }

    /// Any width, odd or fractional, with the fold in the middle, flat, folded or wider than the reservation, at any
    /// text size: an even count of cards filling the grid, none over the fold, at least the minimum width unless the
    /// fold is wider than the reservation.
    @Test func everyWidthGetsAnEvenCountClearOfTheFold() throws {
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
            let minimum = ItemGridMetrics.minimumCellWidth(for: size)
            for width in stride(from: CGFloat(2 * minimum + 64), through: 1_400.5, by: 7.25) {
                for foldWidth in [CGFloat(0), 21.5, 40] {
                    let minX = (width - foldWidth) / 2
                    let layout = try #require(
                        plan(width: width, [division(minX, minX + foldWidth, isActive: foldWidth > 0)], size: size))
                    #expect(layout.leadingColumns == layout.trailingColumns && layout.leadingColumns > 0)
                    #expect(layout.columnCount.isMultiple(of: 2))
                    let excess = max(0, foldWidth - ItemGridMetrics.foldReservation)
                    #expect(layout.columnWidth >= minimum - excess / 2)
                    #expect(layout.leadingInset >= ABSSpacing.large && layout.trailingInset >= ABSSpacing.large)
                    #expect(abs(filledWidth(layout) - width) < 0.001)
                    #expect(cardsClear(layout, ofFoldFrom: minX, to: minX + foldWidth))
                    let gap = foldGap(layout)
                    #expect(gap.start <= minX + 0.001 && gap.end >= minX + foldWidth - 0.001)
                }
            }
        }
    }
}
