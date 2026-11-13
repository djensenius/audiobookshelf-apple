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

    @Test func withoutAFoldTheGridKeepsItsAdaptiveColumns() {
        #expect(ItemGridFold(width: 800, divisions: []) == nil)
        // Laptop pose: the fold runs across, which a vertically scrolling grid doesn't mind.
        #expect(ItemGridFold(width: 800, divisions: [(CGRect(x: 0, y: 400, width: 800, height: 20), true)]) == nil)
        // A fold beside the grid (a split view's other column) doesn't touch it.
        #expect(ItemGridFold(width: 800, divisions: [division(-30, -10), division(810, 830)]) == nil)
        #expect(ItemGridFold(width: 800, divisions: [(.zero, true)]) == nil)
        #expect(ItemGridFold(width: .nan, divisions: [division(390, 410)]) == nil)
    }

    /// Book pose on a width the adaptive grid fills with an odd 5 columns: 2 on each side instead, with the gap over
    /// the fold and the grid's padding outside.
    @Test func aVerticalFoldSplitsAnOddCountEvenly() throws {
        #expect(ItemGridMetrics.columnCount(width: 800, dynamicTypeSize: .large) == 5)
        let fold = try #require(ItemGridFold(width: 800, divisions: [division(390, 410)]))
        #expect(fold == ItemGridFold(width: 800, divisions: [(CGRect(x: 390, y: -200, width: 20, height: 900), true)]))
        let layout = try #require(ItemGridMetrics.foldLayout(fold, dynamicTypeSize: .large))
        #expect(
            layout
                == ItemGridFoldLayout(
                    leadingColumns: 2, trailingColumns: 2, columnWidth: 179, spacing: 16, foldSpacing: 20,
                    leadingInset: 16, trailingInset: 16))
        #expect([0, 1, 2].map(layout.spacing(after:)) == [16, 20, 16])
        #expect(foldGap(layout) == (390, 410))
    }

    /// Lying flat the fold's region is inactive and has no width; the columns still split around it, as many as
    /// once it folds, so they don't move.
    @Test func anInactiveFoldStillSplitsTheColumns() throws {
        let flat = try #require(plan(width: 800, [division(400, 400, isActive: false)]))
        #expect(
            flat
                == ItemGridFoldLayout(
                    leadingColumns: 2, trailingColumns: 2, columnWidth: 180, spacing: 16, foldSpacing: 16,
                    leadingInset: 16, trailingInset: 16))
        #expect(foldGap(flat) == (392, 408))
        let folded = try #require(plan(width: 800, [division(390, 410)]))
        #expect(folded.leadingColumns == flat.leadingColumns && folded.trailingColumns == flat.trailingColumns)
    }

    /// A grid off the fold's centre (a vertical bar on one side) fits the narrower side's columns on both, of one
    /// width; the wider side's extra space goes outside them.
    @Test func theNarrowerSideSetsTheColumns() throws {
        let layout = try #require(plan(width: 700, [division(300, 320)]))
        #expect(
            layout
                == ItemGridFoldLayout(
                    leadingColumns: 1, trailingColumns: 1, columnWidth: 284, spacing: 16, foldSpacing: 20,
                    leadingInset: 16, trailingInset: 96))
        #expect(foldGap(layout) == (300, 320))
        #expect(filledWidth(layout) == 700)
    }

    /// A side too narrow for a card stays empty and the other side's columns keep clear of the fold.
    @Test func aSideTooNarrowForACardIsLeftEmpty() throws {
        let trailing = try #require(plan(width: 600, [division(100, 120)]))
        #expect(
            trailing
                == ItemGridFoldLayout(
                    leadingColumns: 0, trailingColumns: 3, columnWidth: 144, spacing: 16, foldSpacing: 20,
                    leadingInset: 120, trailingInset: 16))
        #expect([0, 1].map(trailing.spacing(after:)) == [16, 16])

        let leading = try #require(plan(width: 600, [division(480, 500)]))
        #expect(
            leading
                == ItemGridFoldLayout(
                    leadingColumns: 3, trailingColumns: 0, columnWidth: 144, spacing: 16, foldSpacing: 20,
                    leadingInset: 16, trailingInset: 120))
        #expect([0, 1].map(leading.spacing(after:)) == [16, 16])
        #expect(filledWidth(trailing) == 600 && filledWidth(leading) == 600)

        // Neither side fits one: the adaptive columns.
        #expect(plan(width: 200, [division(95, 105)]) == nil)
    }

    /// Any width, odd or fractional, with the fold in the middle, flat or folded, at any text size: an even count of
    /// cards at least the minimum width, filling the grid, none over the fold.
    @Test func everyWidthGetsAnEvenCountClearOfTheFold() throws {
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
            let minimum = ItemGridMetrics.minimumCellWidth(for: size)
            for width in stride(from: CGFloat(2 * minimum + 64), through: 1_400.5, by: 7.25) {
                for foldWidth in [CGFloat(0), 21.5] {
                    let minX = (width - foldWidth) / 2
                    let layout = try #require(
                        plan(width: width, [division(minX, minX + foldWidth, isActive: foldWidth > 0)], size: size))
                    #expect(layout.leadingColumns == layout.trailingColumns && layout.leadingColumns > 0)
                    #expect(layout.columnCount.isMultiple(of: 2))
                    #expect(layout.columnWidth >= minimum)
                    #expect(layout.leadingInset >= ABSSpacing.large && layout.trailingInset >= ABSSpacing.large)
                    #expect(abs(filledWidth(layout) - width) < 0.001)
                    let gap = foldGap(layout)
                    #expect(gap.start <= minX + 0.001 && gap.end >= minX + foldWidth - 0.001)
                }
            }
        }
    }
}
