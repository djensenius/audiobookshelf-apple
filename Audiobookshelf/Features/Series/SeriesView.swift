import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The Series section of a book library (legacy `pages/bookshelf/series/index.vue`): the
/// router's library's series by name, a page at a time.
///
/// Builds one ``SeriesListModel`` per store, account and library from `makeServices()`, so a
/// library switch or another account never shows the previous list.
struct SeriesView: View {
    @Environment(\.libraryStore) private var store
    @Environment(Router.self) private var router: Router?
    @State private var host: BrowseModelHost<SeriesListModel>?

    var body: some View {
        let libraryID = router?.libraryID
        let key = BrowseModelKey(store: store, libraryID: libraryID)
        Group {
            if let model = host?.model(for: key) {
                SeriesListContent(model: model)
            } else {
                BrowsePlaceholder(libraryID: libraryID, messages: SeriesPresentation.listMessages)
            }
        }
        .navigationTitle(Text(verbatim: L10n.string(AppTab.series.titleKey)))
        .task(id: key) {
            guard let key, let store else {
                host = nil
                return
            }
            if host?.key != key {
                host = BrowseModelHost(key: key, store: store) { SeriesPresentation.makeList(key: key, services: $0) }
            }
            if let model = host?.model, model.items.isEmpty, !model.reachedEnd {
                await model.loadNextPage()?.value
            }
        }
    }
}

/// The series grid of one model; previews give it a fixture service.
struct SeriesListContent: View {
    let model: SeriesListModel
    @Environment(Router.self) private var router: Router?
    @Environment(\.serverID) private var serverID

    var body: some View {
        let messages = SeriesPresentation.listMessages
        BrowseStateView(state: .resolve(list: model), messages: messages, retry: { retry() }) { failed in
            ScrollView(.vertical) {
                VStack(spacing: ABSSpacing.large) {
                    ItemGrid(elements: model.items) { series in
                        SeriesCard(series: series, serverID: serverID) {
                            BrowsePresentation.open(.series(id: series.id), in: router)
                        }
                        .onAppear { model.itemAppeared(id: series.id) }
                    }
                    BrowsePagingFooter(
                        isLoading: model.isLoading, failed: failed, messageKey: messages.failed, retry: { retry() })
                }
                .padding(.vertical, ABSSpacing.large)
            }
        }
        .refreshable { await model.refresh()?.value }
        .browseRefreshCommand(isDisabled: model.isLoading) { model.refresh() }
    }

    private func retry() {
        BrowsePresentation.retry(model)
    }
}

#if DEBUG
    #Preview("Series") {
        @Previewable @State var model = SeriesAuthorsPreviewData.seriesList()
        NavigationStack {
            SeriesListContent(model: model)
                .navigationTitle(Text(verbatim: L10n.string(AppTab.series.titleKey)))
        }
        .task { await model.loadNextPage()?.value }
        .environment(\.serverID, UUID())
        .absBackground()
    }

    #Preview("Series, failed, dark") {
        @Previewable @State var model = SeriesAuthorsPreviewData.seriesList(fails: true)
        NavigationStack {
            SeriesListContent(model: model)
                .navigationTitle(Text(verbatim: L10n.string(AppTab.series.titleKey)))
        }
        .task { await model.loadNextPage()?.value }
        .absBackground()
        .preferredColorScheme(.dark)
    }
#endif

#Preview("Signed out") {
    NavigationStack { SeriesView() }
        .absBackground()
}
