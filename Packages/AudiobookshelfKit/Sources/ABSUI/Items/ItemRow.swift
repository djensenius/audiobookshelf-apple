import ABSCore
import SwiftUI

/// One item as a list row: a small cover, title, subtitle, series and duration, and a progress
/// badge. Use it in a `List` (port of the legacy list-style item card).
public struct ItemRow: View {
    private let item: ItemSummary
    private let serverID: UUID?
    private let progress: ItemProgress?
    private let context: ItemActionContext
    private let perform: (ItemActionKind) -> Void
    @ScaledMetric(relativeTo: .body) private var coverWidth: CGFloat = 56
    @Environment(\.itemProgressReader) private var progressReader
    @Environment(\.locale) private var locale

    public init(
        item: ItemSummary, serverID: UUID?, progress: ItemProgress? = nil,
        context: ItemActionContext = ItemActionContext(), perform: @escaping (ItemActionKind) -> Void
    ) {
        self.item = item
        self.serverID = serverID
        self.progress = progress
        self.context = context
        self.perform = perform
    }

    public var body: some View {
        let progress = progress ?? progressReader(itemID: item.itemID, episodeID: item.episodeID)
        Button {
            perform(.openDetails)
        } label: {
            HStack(spacing: ABSSpacing.medium) {
                CoverView(
                    key: serverID.flatMap { item.coverKey(serverID: $0, bucket: .small) }, title: item.title,
                    shape: ItemPresentation.defaultShape(item), accessibility: .hidden
                )
                .frame(width: min(coverWidth, 120))
                VStack(alignment: .leading, spacing: ABSSpacing.xxSmall) {
                    Text(verbatim: item.title)
                        .font(.body)
                        .lineLimit(2)
                        .foregroundStyle(ABSColor.foreground)
                    HStack(spacing: ABSSpacing.xxSmall) {
                        if item.isExplicit { ExplicitBadge() }
                        if item.isAbridged { AbridgedBadge() }
                        if let subtitle = ItemPresentation.subtitle(item) {
                            Text(verbatim: subtitle).lineLimit(1)
                        }
                    }
                    if let seriesText = item.seriesText {
                        Text(verbatim: seriesText).lineLimit(1)
                    }
                    if let duration = item.duration {
                        DurationText(seconds: duration, style: .elapsed(showSeconds: false))
                    }
                }
                .font(.caption)
                .foregroundStyle(ABSColor.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
                ProgressBadge(progress: progress)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .itemHover()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ItemPresentation.accessibilityLabel(item)))
        .accessibilityValue(
            Text(verbatim: ItemPresentation.accessibilityValue(item, progress: progress, locale: locale))
        )
        .accessibilityHint(Text(verbatim: L10n.string("SharedOpenDetailsHint")))
        .accessibilityAddTraits(.isButton)
        .itemActions(ItemAction.available(for: item, progress: progress, context: context), perform: perform)
    }
}

#Preview("Item rows") {
    let serverID = UUID()
    List(SampleLibrary.books) { book in
        let item = ItemSummary(item: book)
        ItemRow(item: item, serverID: serverID, progress: SampleLibrary.progress[item.progressKey]) { _ in }
    }
}

#Preview("Item rows, dark, largest text") {
    List {
        ItemRow(item: ItemSummary(item: SampleLibrary.warlordOfMars), serverID: nil) { _ in }
    }
    .environment(\.dynamicTypeSize, .accessibility5)
    .preferredColorScheme(.dark)
}
