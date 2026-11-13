import SwiftUI

/// A fold running down through an ``ItemGrid`` (the iPhone Duo's in book pose, #85): where its `.division` reserved
/// region runs, from the grid's leading edge, and the grid's width.
///
/// Unlike the player's fold, an inactive region counts: it is where the display folds once it does, and keeping the
/// columns clear of it while the display lies flat means they don't move as it folds and unfolds.
struct ItemGridFold: Equatable, Sendable {
    /// The grid's width, its horizontal padding included.
    let width: CGFloat
    /// Where the fold starts and ends across the grid; the same for a flat display's zero-width region.
    let minX: CGFloat
    let maxX: CGFloat

    /// The first of `divisions` (the `.division` reserved regions, inactive ones included) that runs down through a
    /// grid `width` wide; `nil` without one, so the grid keeps its adaptive columns. A region taller than wide runs
    /// down (book pose); one wider than tall runs across (laptop pose), which a vertically scrolling grid ignores.
    init?(width: CGFloat, divisions: [(frame: CGRect, isActive: Bool)]) {
        guard width.isFinite,
            let frame = divisions.lazy.map(\.frame).first(where: {
                $0.height > $0.width && $0.minX.isFinite && $0.maxX.isFinite && $0.midX > 0 && $0.midX < width
            })
        else { return nil }
        self.width = width
        minX = frame.minX
        maxX = frame.maxX
    }
}

/// An ``ItemGrid``'s columns around a fold (``ItemGridFold``): as many on each side, of one width, with a gap
/// covering the fold, so the count is even and no card straddles it. A side too narrow for a card is left empty.
struct ItemGridFoldLayout: Equatable, Sendable {
    /// The columns before the fold and after it.
    let leadingColumns: Int
    let trailingColumns: Int
    /// Every column's width, at least the minimum cell width.
    let columnWidth: CGFloat
    /// The space between columns on the same side.
    let spacing: CGFloat
    /// The space between the last column before the fold and the first after it, covering the fold.
    let foldSpacing: CGFloat
    /// The space before the first column and after the last; the narrower side keeps the grid's padding.
    let leadingInset: CGFloat
    let trailingInset: CGFloat

    var columnCount: Int { leadingColumns + trailingColumns }

    /// The space after the column at `index`, from the leading edge: the fold's gap after the last column before it.
    func spacing(after index: Int) -> CGFloat {
        index == leadingColumns - 1 && trailingColumns > 0 ? foldSpacing : spacing
    }
}

extension ItemGridMetrics {
    /// The columns of an ``ItemGrid`` with `spacing` around `fold` at `dynamicTypeSize`; `nil` when neither side
    /// fits a card, so the grid keeps its adaptive columns.
    static func foldLayout(
        _ fold: ItemGridFold, dynamicTypeSize: DynamicTypeSize, spacing: CGFloat = ABSSpacing.large
    ) -> ItemGridFoldLayout? {
        let padding = ABSSpacing.large
        let minimum = minimumCellWidth(for: dynamicTypeSize)
        // The gap is at least the usual spacing, centred on a fold narrower than that (a flat display's).
        let foldSpacing = max(spacing, fold.maxX - fold.minX)
        let gapStart = (fold.minX + fold.maxX - foldSpacing) / 2
        let gapEnd = gapStart + foldSpacing
        let leadingSpace = gapStart - padding
        let trailingSpace = fold.width - padding - gapEnd

        func fitting(_ space: CGFloat) -> Int {
            let columns = ((space + spacing) / (minimum + spacing)).rounded(.down)
            return columns.isFinite && columns > 0 ? Int(columns) : 0
        }
        func width(of columns: Int, in space: CGFloat) -> CGFloat {
            (space - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        }

        let perSide = min(fitting(leadingSpace), fitting(trailingSpace))
        if perSide > 0 {
            // The narrower side sets the width, so both sides' cards match; the wider side's extra goes outside.
            let columnWidth = width(of: perSide, in: min(leadingSpace, trailingSpace))
            let side = CGFloat(perSide) * columnWidth + CGFloat(perSide - 1) * spacing
            return ItemGridFoldLayout(
                leadingColumns: perSide, trailingColumns: perSide, columnWidth: columnWidth, spacing: spacing,
                foldSpacing: foldSpacing, leadingInset: gapStart - side, trailingInset: fold.width - gapEnd - side)
        }
        let leading = fitting(leadingSpace)
        if leading > 0 {
            return ItemGridFoldLayout(
                leadingColumns: leading, trailingColumns: 0, columnWidth: width(of: leading, in: leadingSpace),
                spacing: spacing, foldSpacing: foldSpacing, leadingInset: padding,
                trailingInset: fold.width - gapStart)
        }
        let trailing = fitting(trailingSpace)
        if trailing > 0 {
            return ItemGridFoldLayout(
                leadingColumns: 0, trailingColumns: trailing, columnWidth: width(of: trailing, in: trailingSpace),
                spacing: spacing, foldSpacing: foldSpacing, leadingInset: gapEnd, trailingInset: padding)
        }
        return nil
    }
}
