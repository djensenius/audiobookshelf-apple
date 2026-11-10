import ABSCore
import SwiftUI

/// Sizing rules for ``ItemGrid``.
enum ItemGridMetrics {
    /// The narrowest a cell gets. It grows with Dynamic Type so large text gets fewer, wider
    /// columns instead of truncated titles.
    static func minimumCellWidth(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall, .small, .medium, .large: 140
        case .xLarge, .xxLarge, .xxxLarge: 160
        default: 220
        }
    }
}

/// A lazy grid of cards with adaptive columns. The column count follows the width it is given
/// (so it fits phones, iPad split views and Mac windows) and the Dynamic Type size, with no
/// per-cell `GeometryReader`.
///
/// Cells are keyed by `Element.ID`. A sparse, paged list should give each position a stable
/// ID, such as its index within the query generation.
public struct ItemGrid<Element: Identifiable, Cell: View>: View {
    private let elements: [Element]
    private let spacing: CGFloat
    private let cell: (Element) -> Cell
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        elements: [Element], spacing: CGFloat = ABSSpacing.large, @ViewBuilder cell: @escaping (Element) -> Cell
    ) {
        self.elements = elements
        self.spacing = spacing
        self.cell = cell
    }

    public var body: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: ItemGridMetrics.minimumCellWidth(for: dynamicTypeSize)), spacing: spacing,
                    alignment: .top)
            ], spacing: spacing
        ) {
            ForEach(elements) { element in
                cell(element)
            }
        }
        .padding(.horizontal, ABSSpacing.large)
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
