import ABSCore
import SwiftUI

/// A series as a fan of its first covers with its name and book count (port of legacy
/// `LazySeriesCard.vue`). A tap calls `onOpen`.
public struct SeriesCard: View {
    private let series: SeriesSummary
    private let serverID: UUID?
    private let onOpen: () -> Void

    public init(series: SeriesSummary, serverID: UUID?, onOpen: @escaping () -> Void) {
        self.series = series
        self.serverID = serverID
        self.onOpen = onOpen
    }

    public var body: some View {
        let count = ItemPresentation.bookCount(series.bookCount)
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
                GroupCoverView(
                    name: series.name,
                    keys: serverID.map { id in series.covers.map { $0.key(serverID: id) } } ?? []
                )
                .aspectRatio(1 / CoverShape.book.aspectRatio, contentMode: .fit)
                Text(verbatim: series.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                    .foregroundStyle(ABSColor.foreground)
                Text(verbatim: count)
                    .font(.caption)
                    .foregroundStyle(ABSColor.mutedForeground)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .itemHover()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(series.name), \(count)"))
        .accessibilityHint(Text(verbatim: L10n.string("SharedOpenDetailsHint")))
        .accessibilityAddTraits(.isButton)
    }
}

#Preview("Series card") {
    HStack(alignment: .top) {
        ForEach(SampleLibrary.series) {
            SeriesCard(series: SeriesSummary(series: $0), serverID: UUID()) {}
                .frame(width: 160)
        }
    }
    .padding()
    .absBackground()
}
