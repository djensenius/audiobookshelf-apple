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
/// covering the fold, so the count is even and no card straddles it. A side too narrow for a card is left empty;
/// when neither side fits one, narrower cards still keep to their sides.
struct ItemGridFoldLayout: Equatable, Sendable {
    /// The columns before the fold and after it.
    let leadingColumns: Int
    let trailingColumns: Int
    /// Every column's width: at least the minimum cell width, unless neither side fits one or the fold is wider than
    /// ``ItemGridMetrics/foldReservation``.
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
    /// The gap kept over a fold whatever its width in the current pose. Lying flat its region has no width and folded
    /// it has some; keeping the same gap for both leaves every card where it is as the display folds and unfolds. A
    /// fold wider than this widens the gap and narrows the columns, but keeps their count.
    static let foldReservation = ABSSpacing.xxLarge

    /// The columns of an ``ItemGrid`` with `spacing` around `fold` at `dynamicTypeSize`, none of them over the fold.
    ///
    /// The count comes from the room beside ``foldReservation`` (or `spacing`, if wider) centred on the fold, so it is
    /// the same for any fold width at the same grid width; the width comes from the room beside the actual gap.
    /// - Each side gets as many columns as the narrower side fits at the minimum cell width.
    /// - If only one side fits one, that side gets its columns and the other stays empty.
    /// - If neither does, the cards get narrower than the minimum instead of crossing the fold: one on each side, unless
    ///   the narrower side's would be under half the minimum and under half the wider side's room; then one on the
    ///   wider side.
    ///
    /// `nil` only when neither side has any room, so the grid keeps its adaptive columns.
    static func foldLayout(
        _ fold: ItemGridFold, dynamicTypeSize: DynamicTypeSize, spacing: CGFloat = ABSSpacing.large
    ) -> ItemGridFoldLayout? {
        let padding = ABSSpacing.large
        let minimum = minimumCellWidth(for: dynamicTypeSize)
        let centre = (fold.minX + fold.maxX) / 2
        let reserved = max(spacing, foldReservation)
        // Centred on the fold and at least the reservation, so a flat display's zero-width region gets a folded one's.
        let foldSpacing = max(reserved, fold.maxX - fold.minX)
        let gapStart = centre - foldSpacing / 2
        let gapEnd = centre + foldSpacing / 2
        func room(beside gap: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
            (centre - gap / 2 - padding, fold.width - padding - centre - gap / 2)
        }
        let planned = room(beside: reserved)
        let actual = room(beside: foldSpacing)

        func fitting(_ space: CGFloat) -> Int {
            let columns = ((space + spacing) / (minimum + spacing)).rounded(.down)
            return columns.isFinite && columns > 0 ? Int(columns) : 0
        }
        let leadingFit = fitting(planned.leading)
        let trailingFit = fitting(planned.trailing)
        let narrower = min(planned.leading, planned.trailing)
        let wider = max(planned.leading, planned.trailing)
        let counts: (leading: Int, trailing: Int)
        if min(leadingFit, trailingFit) > 0 {
            counts = (min(leadingFit, trailingFit), min(leadingFit, trailingFit))
        } else if leadingFit > 0 || trailingFit > 0 {
            counts = (leadingFit, trailingFit)
        } else if wider <= 0 {
            return nil
        } else if narrower >= min(minimum, wider) / 2 {
            counts = (1, 1)
        } else {
            counts = planned.leading >= planned.trailing ? (1, 0) : (0, 1)
        }

        // The narrower side with columns sets their width, so every card matches; the other side's extra goes
        // outside its columns.
        func width(of columns: Int, in space: CGFloat) -> CGFloat {
            (space - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        }
        let widths =
            (counts.leading > 0 ? [width(of: counts.leading, in: actual.leading)] : [])
            + (counts.trailing > 0 ? [width(of: counts.trailing, in: actual.trailing)] : [])
        guard let columnWidth = widths.min(), columnWidth.isFinite, columnWidth > 0 else { return nil }
        func extent(of columns: Int) -> CGFloat {
            CGFloat(columns) * columnWidth + CGFloat(columns - 1) * spacing
        }
        return ItemGridFoldLayout(
            leadingColumns: counts.leading, trailingColumns: counts.trailing, columnWidth: columnWidth,
            spacing: spacing, foldSpacing: foldSpacing,
            leadingInset: counts.leading > 0 ? gapStart - extent(of: counts.leading) : gapEnd,
            trailingInset: counts.trailing > 0
                ? fold.width - gapEnd - extent(of: counts.trailing) : fold.width - gapStart)
    }
}
