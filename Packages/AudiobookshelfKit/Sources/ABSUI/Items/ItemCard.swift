import ABSCore
import SwiftUI

/// One item as a cover with its title and subtitle underneath, for grids and shelves (port of
/// legacy `LazyBookCard.vue`). The width comes from the parent.
///
/// The card is one VoiceOver element: the label speaks title, subtitle and series, the value
/// the progress, and the actions mirror the context menu. A tap performs ``ItemActionKind/openDetails``.
public struct ItemCard: View {
    private let item: ItemSummary
    private let serverID: UUID?
    private let progress: ItemProgress?
    private let shape: CoverShape
    private let context: ItemActionContext
    private let perform: (ItemActionKind) -> Void
    @Environment(\.itemProgressReader) private var progressReader
    @Environment(\.locale) private var locale

    /// - Parameters:
    ///   - serverID: The connection the cover loads from; `nil` shows the placeholder.
    ///   - progress: Overrides the environment's ``ItemProgressReader``.
    ///   - shape: The cover shape; podcasts and episodes default to square.
    public init(
        item: ItemSummary, serverID: UUID?, progress: ItemProgress? = nil, shape: CoverShape? = nil,
        context: ItemActionContext = ItemActionContext(), perform: @escaping (ItemActionKind) -> Void
    ) {
        self.item = item
        self.serverID = serverID
        self.progress = progress
        self.shape = shape ?? ItemPresentation.defaultShape(item)
        self.context = context
        self.perform = perform
    }

    public var body: some View {
        let progress = ItemPresentation.progress(for: item, explicit: progress, reader: progressReader)
        Button {
            perform(.openDetails)
        } label: {
            VStack(alignment: .leading, spacing: ABSSpacing.xSmall) {
                CoverView(
                    key: serverID.flatMap { item.coverKey(serverID: $0) }, title: item.title, author: item.subtitle,
                    shape: shape, progress: progress?.isInProgress == true ? progress?.fraction : nil,
                    isFinished: progress?.isFinished ?? false, accessibility: .hidden)
                Text(verbatim: item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                    .foregroundStyle(ABSColor.foreground)
                HStack(spacing: ABSSpacing.xxSmall) {
                    if item.isExplicit { ExplicitBadge() }
                    if item.isAbridged { AbridgedBadge() }
                    if let subtitle = ItemPresentation.subtitle(item) {
                        Text(verbatim: subtitle)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(ABSColor.mutedForeground)
                if item.isMissing { MissingIndicator() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

#Preview("Item cards") {
    let serverID = UUID()
    ScrollView(.horizontal) {
        HStack(alignment: .top) {
            ForEach([SampleLibrary.frankenstein, SampleLibrary.prideAndPrejudice, SampleLibrary.princessOfMars]) {
                let item = ItemSummary(item: $0)
                ItemCard(item: item, serverID: serverID, progress: SampleLibrary.progress[item.progressKey]) { _ in }
                    .frame(width: 140)
            }
            ItemCard(item: ItemSummary(item: SampleLibrary.episodeItems[0]), serverID: serverID) { _ in }
                .frame(width: 140)
        }
        .padding()
    }
    .absBackground()
}

#Preview("Item cards, dark, largest text") {
    ItemCard(item: ItemSummary(item: SampleLibrary.warlordOfMars), serverID: nil) { _ in }
        .frame(width: 200)
        .padding()
        .absBackground()
        .environment(\.dynamicTypeSize, .accessibility5)
        .preferredColorScheme(.dark)
}
