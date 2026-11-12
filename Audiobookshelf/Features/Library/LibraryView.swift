import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The Library tab's default screen (legacy `pages/bookshelf/library.vue`): the router's library's items as cards or
/// rows, with the account's saved sort, filter and view for it, a page at a time. Builds one ``LibraryItemsModel``
/// per store, account and library from `makeServices()`, so a library switch or another account never shows the
/// previous items.
struct LibraryView: View {
    @Environment(\.libraryStore) private var store
    @Environment(Router.self) private var router: Router?
    @State private var host: LibraryModelHost?
    /// The screen's width once measured; the grid's columns decide the paging.
    @State private var width: CGFloat?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let libraryID = router?.libraryID
        let key = BrowseModelKey(store: store, libraryID: libraryID)
        let mediaType = libraryID.flatMap { store?.mediaType(libraryID: $0) }
        let model = host?.model(for: key)
        let paging = model.map {
            LibraryPresentation.paging(
                width: width, dynamicTypeSize: dynamicTypeSize, viewMode: $0.preferences.viewMode)
        }
        Group {
            if let host, let model {
                LibraryContent(model: model)
                    // TODO(#181): drop this once the shell sets `itemProgressReader` from the same store.
                    .environment(\.itemProgressReader, host.progressReader)
            } else {
                // Until the library's type is known, the placeholder waits for (or retries) the libraries.
                BrowsePlaceholder(
                    libraryID: mediaType == nil ? nil : libraryID,
                    messages: LibraryPresentation.messages(for: mediaType))
            }
        }
        .navigationTitle(Text(verbatim: L10n.string(AppTab.library.titleKey)))
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
        .onChange(of: paging) { _, paging in
            if let paging, let model { paging.apply(to: model) }
        }
        // The first page waits for the width, so it is sized for the grid's columns.
        .task(id: LibraryTaskID(key: key, mediaType: mediaType, isMeasured: width != nil)) {
            host = LibraryPresentation.updated(host, for: key, mediaType: mediaType, store: store)
            guard let model = host?.model, width != nil else { return }
            LibraryPresentation.paging(
                width: width, dynamicTypeSize: dynamicTypeSize, viewMode: model.preferences.viewMode
            ).apply(to: model)
            if model.items.isEmpty, !model.reachedEnd {
                await model.load()?.value
            }
        }
    }
}

/// What the Library screen's task runs for: a new key, the library's type once it is known, or the first width.
private struct LibraryTaskID: Hashable {
    let key: BrowseModelKey?
    let mediaType: MediaType?
    let isMeasured: Bool
}

/// The items of one model as a grid or list, with the count in the title area; previews give it a fixture service.
struct LibraryContent: View {
    let model: LibraryItemsModel
    /// The last user refresh failed and nothing loaded since.
    @State private var refreshFailed = false
    /// Successful user refreshes; cards report appearing again after each (as in ``BrowseItemGrid``).
    @State private var refreshes = 0

    var body: some View {
        let messages = LibraryPresentation.messages(for: model.mediaType)
        BrowseStateView(state: LibraryPresentation.state(of: model), messages: messages, retry: { retry() }) {
            failed in
            let placement = BrowsePresentation.failurePlacement(failed: failed, refreshFailed: refreshFailed)
            ScrollView(.vertical) {
                VStack(spacing: ABSSpacing.large) {
                    if placement == .top {
                        BrowseFailureRow(messageKey: messages.failed, retry: { Task { await refresh() } })
                    }
                    switch model.preferences.viewMode {
                    case .grid:
                        BrowseItemGrid(
                            elements: model.items, item: { $0 }, onAppear: { model.list.itemAppeared(id: $0.id) },
                            appearanceID: refreshes)
                    case .list:
                        LibraryItemList(
                            items: model.items, onAppear: { model.list.itemAppeared(id: $0.id) },
                            appearanceID: refreshes)
                    }
                    BrowsePagingFooter(
                        isLoading: model.isLoading, failed: placement == .footer, messageKey: messages.failed,
                        retry: { retry() })
                }
                .padding(.vertical, ABSSpacing.large)
            }
        }
        .navigationSubtitle(
            Text(verbatim: LibraryPresentation.countText(total: model.total, mediaType: model.mediaType) ?? "")
        )
        .refreshable { await refresh() }
        .refreshCommand(.root(.library), isDisabled: model.isLoading) { Task { await refresh() } }
        .onChange(of: model.error == nil) { _, cleared in
            if cleared { refreshFailed = false }
        }
    }

    private func refresh() async {
        refreshFailed = await BrowsePresentation.refresh(model.list)
        if !refreshFailed { refreshes += 1 }
    }

    private func retry() {
        BrowsePresentation.retry(model.list)
    }
}

#if DEBUG
    /// Serves ``SampleLibrary``'s books, or fails every request when `fails`.
    private struct LibraryPreviewService: LibraryService {
        struct Failure: Error {}

        var fails = false

        func libraries() async throws -> [Library] { [] }
        func library(id: String) async throws -> LibraryWithFilterData { throw Failure() }
        func personalizedShelves(libraryID: String) async throws -> [Shelf] { [] }

        func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<ABSCore.LibraryItem> {
            if fails { throw Failure() }
            let books = SampleLibrary.books
            return PagedResults(results: books, total: books.count, limit: query.limit ?? 0, page: query.page ?? 0)
        }
    }

    @MainActor
    private func previewModel(_ viewMode: LibraryViewMode = .grid, fails: Bool = false) -> LibraryItemsModel {
        LibraryItemsModel(
            client: LibraryPreviewService(fails: fails), libraryID: SampleLibrary.libraryID, mediaType: .book,
            stored: LibraryViewPreferences(viewMode: viewMode), map: { ItemSummary(item: $0) })
    }

    #Preview("Grid") {
        @Previewable @State var model = previewModel()
        NavigationStack {
            LibraryContent(model: model)
                .navigationTitle(Text(verbatim: L10n.string(AppTab.library.titleKey)))
        }
        .task { await model.load()?.value }
        .environment(\.serverID, UUID())
        .absBackground()
    }

    #Preview("List, largest text, dark") {
        @Previewable @State var model = previewModel(.list)
        NavigationStack {
            LibraryContent(model: model)
                .navigationTitle(Text(verbatim: L10n.string(AppTab.library.titleKey)))
        }
        .task { await model.load()?.value }
        .environment(\.serverID, UUID())
        .environment(\.dynamicTypeSize, .accessibility3)
        .absBackground()
        .preferredColorScheme(.dark)
    }

    #Preview("Failed") {
        @Previewable @State var model = previewModel(fails: true)
        NavigationStack {
            LibraryContent(model: model)
                .navigationTitle(Text(verbatim: L10n.string(AppTab.library.titleKey)))
        }
        .task { await model.load()?.value }
        .absBackground()
    }
#endif

#Preview("Signed out") {
    NavigationStack { LibraryView() }
        .absBackground()
}
