import ABSCore
import SwiftUI

/// Sizing rules for ``ItemGrid``.
public enum ItemGridMetrics {
    /// The narrowest a cell gets. It grows with Dynamic Type so large text gets fewer, wider
    /// columns instead of truncated titles.
    public static func minimumCellWidth(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall, .small, .medium, .large: 140
        case .xLarge, .xxLarge, .xxxLarge: 160
        default: 220
        }
    }

    /// The columns an ``ItemGrid`` with the default spacing shows in `width` (its full width, with its
    /// horizontal padding), as the adaptive layout fits them: as many minimum-width cells and spacings as fit,
    /// at least one.
    public static func columnCount(width: CGFloat, dynamicTypeSize: DynamicTypeSize) -> Int {
        let spacing = ABSSpacing.large
        let available = width - 2 * ABSSpacing.large
        let fitting = ((available + spacing) / (minimumCellWidth(for: dynamicTypeSize) + spacing)).rounded(.down)
        return max(1, fitting.isFinite ? Int(fitting) : 1)
    }
}

/// A lazy grid of cards with adaptive columns. The column count follows the width it is given
/// (so it fits phones, iPad split views and Mac windows) and the Dynamic Type size, with no
/// per-cell `GeometryReader`.
///
/// From iOS 27.1, a fold running down through the grid (an iPhone Duo in book pose, or lying flat) splits the
/// columns evenly around it instead (#85, ``ItemGridFoldLayout``), so no card straddles it.
///
/// Cells are keyed by `Element.ID`. A sparse, paged list should give each position a stable
/// ID, such as its index within the query generation.
public struct ItemGrid<Element: Identifiable, Cell: View>: View {
    private let elements: [Element]
    private let spacing: CGFloat
    private let cell: (Element) -> Cell
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The fold through the grid, once measured (``ItemGridFoldReader``).
    @State private var fold: ItemGridFold?

    public init(
        elements: [Element], spacing: CGFloat = ABSSpacing.large, @ViewBuilder cell: @escaping (Element) -> Cell
    ) {
        self.elements = elements
        self.spacing = spacing
        self.cell = cell
    }

    public var body: some View {
        let layout = fold.flatMap {
            ItemGridMetrics.foldLayout($0, dynamicTypeSize: dynamicTypeSize, spacing: spacing)
        }
        LazyVGrid(columns: columns(layout), spacing: spacing) {
            ForEach(elements) { element in
                cell(element)
            }
        }
        .padding(.leading, layout?.leadingInset ?? ABSSpacing.large)
        .padding(.trailing, layout?.trailingInset ?? ABSSpacing.large)
        .modifier(ItemGridFoldReader(fold: $fold))
    }

    /// Fixed columns around a fold, or adaptive ones without.
    private func columns(_ layout: ItemGridFoldLayout?) -> [GridItem] {
        guard let layout else {
            return [
                GridItem(
                    .adaptive(minimum: ItemGridMetrics.minimumCellWidth(for: dynamicTypeSize)), spacing: spacing,
                    alignment: .top)
            ]
        }
        return (0..<layout.columnCount).map {
            GridItem(.fixed(layout.columnWidth), spacing: layout.spacing(after: $0), alignment: .top)
        }
    }
}

/// Measures the fold an ``ItemGrid`` lies across from iOS 27.1: its `.division` reserved regions, inactive ones
/// included (``ItemGridFold``). Before that and on macOS it measures nothing, so the grid keeps its adaptive
/// columns.
private struct ItemGridFoldReader: ViewModifier {
    @Binding var fold: ItemGridFold?

    func body(content: Content) -> some View {
        #if os(iOS)
            if #available(iOS 27.1, *) {
                content
                    // The measured width is the offered one, whatever the columns add up to, even when the fixed
                    // columns of a wider proposal would otherwise hold it wider than a narrower one.
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .onGeometryChange(for: ItemGridFold?.self) { proxy in
                        ItemGridFold(
                            width: proxy.size.width,
                            divisions: proxy.reservedRegions(kind: .division, options: .includeInactive).map {
                                ($0.frame, $0.isActive)
                            })
                    } action: {
                        fold = $0
                    }
            } else {
                content
            }
        #else
            content
        #endif
    }
}

#Preview("Grid") {
    let serverID = UUID()
    ScrollView {
        ItemGrid(elements: SampleLibrary.books.map { ItemSummary(item: $0) }) { item in
            ItemCard(item: item, serverID: serverID, progress: SampleLibrary.progress[item.progressKey]) { _ in }
        }
    }
    .absBackground()
}

#Preview("Grid, dark, largest text") {
    ScrollView {
        ItemGrid(elements: SampleLibrary.books.map { ItemSummary(item: $0) }) { item in
            ItemCard(item: item, serverID: nil) { _ in }
        }
    }
    .absBackground()
    .environment(\.dynamicTypeSize, .accessibility5)
    .preferredColorScheme(.dark)
}
