import ABSCore
import SwiftUI

/// A titled horizontal shelf of cards (port of legacy `Shelf.vue`): a header with an optional
/// "show all" action, lazily created cards, and a message when it's empty. The title is a
/// VoiceOver heading and the shelf a container named after it.
public struct ShelfRow<Element: Identifiable, Card: View>: View {
    private let title: String
    private let elements: [Element]
    private let onShowAll: (() -> Void)?
    private let card: (Element) -> Card
    @ScaledMetric private var cardWidth: CGFloat

    /// - Parameters:
    ///   - cardWidth: The width of one card at the default text size; it scales with Dynamic Type.
    ///   - onShowAll: Shows the "show all" button when set.
    public init(
        title: String, elements: [Element], cardWidth: CGFloat = 140, onShowAll: (() -> Void)? = nil,
        @ViewBuilder card: @escaping (Element) -> Card
    ) {
        self.title = title
        self.elements = elements
        self.onShowAll = onShowAll
        self.card = card
        _cardWidth = ScaledMetric(wrappedValue: cardWidth, relativeTo: .body)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ABSSpacing.small) {
            HStack {
                Text(verbatim: title)
                    .font(.headline)
                    .foregroundStyle(ABSColor.foreground)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let onShowAll {
                    Button(L10n.string("LabelShowAll"), action: onShowAll)
                        .font(.subheadline)
                        .accessibilityLabel(
                            Text(verbatim: ItemPresentation.showAllAccessibilityLabel(shelfTitle: title)))
                }
            }
            .padding(.horizontal, ABSSpacing.large)
            if elements.isEmpty {
                Text(verbatim: L10n.string("MessageNoItems"))
                    .font(.subheadline)
                    .foregroundStyle(ABSColor.mutedForeground)
                    .padding(.horizontal, ABSSpacing.large)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: ABSSpacing.medium) {
                        ForEach(elements) { element in
                            card(element).frame(width: min(cardWidth, 280))
                        }
                    }
                    .padding(.horizontal, ABSSpacing.large)
                }
                .scrollIndicators(.hidden)
            }
        }
        // One container per shelf, entered from its heading on the rotor.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: title))
    }
}

#Preview("Shelf") {
    let serverID = UUID()
    VStack {
        ShelfRow(
            title: "Continue Listening", elements: SampleLibrary.books.map { ItemSummary(item: $0) },
            onShowAll: {}
        ) { item in
            ItemCard(item: item, serverID: serverID, progress: SampleLibrary.progress[item.progressKey]) { _ in }
        }
        ShelfRow(title: "Empty", elements: [ItemSummary]()) { item in
            ItemCard(item: item, serverID: serverID) { _ in }
        }
    }
    .absBackground()
}
