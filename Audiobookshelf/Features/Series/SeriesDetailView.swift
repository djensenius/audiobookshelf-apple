import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// One series (legacy `pages/bookshelf/series/_id.vue`): its description, Continue Series and
/// its books in the server's sequence order, each with its progress.
///
/// Builds one ``SeriesDetailModel`` per store, account and library from `makeServices()`.
struct SeriesDetailView: View {
    let seriesID: String
    @Environment(\.libraryStore) private var store
    @Environment(Router.self) private var router: Router?
    @State private var host: BrowseModelHost<SeriesDetailModel>?

    var body: some View {
        let libraryID = router?.libraryID
        let key = BrowseModelKey(store: store, libraryID: libraryID, entityID: seriesID)
        Group {
            if let host, let model = host.model(for: key) {
                SeriesDetailContent(model: model)
                    // TODO(#181): drop this once the shell sets `itemProgressReader` from the same store.
                    .environment(\.itemProgressReader, host.progressReader)
            } else {
                BrowsePlaceholder(libraryID: libraryID, messages: SeriesPresentation.detailMessages)
                    .navigationTitle(Text(verbatim: L10n.string("LabelSeries")))
            }
        }
        .task(id: key) {
            host = .updated(host, for: key, store: store) { key, services, progress in
                SeriesDetailModel(seriesID: seriesID, libraryID: key.libraryID, service: services, cache: progress)
            }
            await host?.model.loadIfNeeded()
        }
    }
}

/// The series screen for one model; previews give it a fixture service.
struct SeriesDetailContent: View {
    let model: SeriesDetailModel

    var body: some View {
        let messages = SeriesPresentation.detailMessages
        BrowseStateView(state: SeriesPresentation.state(of: model), messages: messages, retry: { reload() }) {
            failed in
            if let detail = model.detail {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: ABSSpacing.large) {
                        if failed {
                            BrowseFailureRow(messageKey: messages.failed, retry: { reload() })
                        }
                        SeriesDetailHeader(detail: detail, continueBook: model.continueBook)
                        if detail.books.isEmpty {
                            Text(verbatim: L10n.string("MessageNoItemsFound"))
                                .foregroundStyle(ABSColor.mutedForeground)
                                .padding(.horizontal, ABSSpacing.large)
                        } else {
                            BrowseItemGrid(
                                elements: detail.books, item: { SeriesPresentation.card(for: $0, in: detail.name) },
                                badge: { SeriesPresentation.sequenceBadge($0.sequence) })
                        }
                    }
                    .padding(.vertical, ABSSpacing.large)
                }
            }
        }
        .navigationTitle(Text(verbatim: model.detail?.name ?? L10n.string("LabelSeries")))
        .refreshable { await model.load() }
        .browseRefreshCommand(isDisabled: model.isLoading) { reload() }
    }

    private func reload() {
        Task { await model.load() }
    }
}

/// The description and Continue Series, which opens the first unfinished book.
private struct SeriesDetailHeader: View {
    let detail: SeriesDetail
    let continueBook: SeriesBook?
    @Environment(Router.self) private var router: Router?

    var body: some View {
        VStack(alignment: .leading, spacing: ABSSpacing.medium) {
            if let description = detail.description {
                ExpandableText(description, collapsedLineLimit: 4)
            }
            if let continueBook {
                Button {
                    BrowsePresentation.open(SeriesPresentation.continueRoute(for: continueBook), in: router)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: ABSSpacing.xxSmall) {
                            Text(verbatim: L10n.string("LabelContinueSeries"))
                                .font(.headline)
                            Text(verbatim: continueBook.summary.title)
                                .font(.subheadline)
                                .lineLimit(2)
                        }
                    } icon: {
                        Image(systemName: "book")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(Text(verbatim: SeriesPresentation.continueAccessibilityLabel(for: continueBook)))
                .accessibilityHint(Text(verbatim: L10n.string("SharedOpenDetailsHint")))
            }
        }
        .padding(.horizontal, ABSSpacing.large)
    }
}

#if DEBUG
    #Preview("Series detail") {
        @Previewable @State var model = SeriesAuthorsPreviewData.seriesDetail()
        NavigationStack {
            SeriesDetailContent(model: model)
        }
        .task { await model.load() }
        .environment(\.serverID, UUID())
        .environment(\.itemProgressReader, SeriesAuthorsPreviewData.progressReader)
        .absBackground()
    }

    #Preview("Series detail, largest text, dark") {
        @Previewable @State var model = SeriesAuthorsPreviewData.seriesDetail()
        NavigationStack {
            SeriesDetailContent(model: model)
        }
        .task { await model.load() }
        .environment(\.itemProgressReader, SeriesAuthorsPreviewData.progressReader)
        .environment(\.dynamicTypeSize, .accessibility3)
        .absBackground()
        .preferredColorScheme(.dark)
    }

    #Preview("Series detail, failed") {
        @Previewable @State var model = SeriesAuthorsPreviewData.seriesDetail(fails: true)
        NavigationStack {
            SeriesDetailContent(model: model)
        }
        .task { await model.load() }
        .absBackground()
    }
#endif

#Preview("Series detail, signed out") {
    NavigationStack { SeriesDetailView(seriesID: "ser_barsoom") }
        .absBackground()
}
