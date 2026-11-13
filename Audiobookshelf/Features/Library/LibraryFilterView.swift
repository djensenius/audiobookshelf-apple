import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import SwiftUI

/// The router's library filtered to one narrator, tag or genre (``Route/libraryFilter(kind:value:)`` and the legacy
/// ``Route/narrator(name:)``), titled "Narrator: Stephen Fry". The filter is pinned: shown and queried, never saved,
/// so the Library tab keeps its own filter (unlike legacy `library.vue`, as this screen can sit on any tab's stack).
/// Sort and view changes here still save for the library. There is no filter button. A filter the library's type
/// can't query (a narrator in a podcast library) shows no items rather than the whole library.
struct LibraryFilterView: View {
    let kind: LibraryFilterKind
    let value: String
    @Environment(\.libraryStore) private var store
    @Environment(Router.self) private var router: Router?
    @State private var host: LibraryModelHost?
    /// The screen's width once measured; the grid's columns decide the paging.
    @State private var width: CGFloat?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let libraryID = router?.libraryID
        let key = LibraryFilterPresentation.modelKey(store: store, libraryID: libraryID, kind: kind, value: value)
        let mediaType = libraryID.flatMap { store?.mediaType(libraryID: $0) }
        let model = host?.model(for: key)
        let paging = model.map {
            LibraryPresentation.paging(
                width: width, dynamicTypeSize: dynamicTypeSize, viewMode: $0.preferences.viewMode)
        }
        let topRoute = router.flatMap { $0[path: $0.selectedTab].last }
        Group {
            if let model {
                LibraryContent(
                    model: model,
                    placement: LibraryFilterPresentation.placement(kind: kind, value: value, topRoute: topRoute),
                    messages: LibraryFilterPresentation.messages(for: model)
                )
            } else {
                // Until the library's type is known, the placeholder waits for (or retries) the libraries.
                BrowsePlaceholder(
                    libraryID: mediaType == nil ? nil : libraryID,
                    messages: LibraryPresentation.messages(for: mediaType))
            }
        }
        .navigationTitle(Text(verbatim: LibraryFilterPresentation.title(kind: kind, value: value)))
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
        .onChange(of: paging) { _, paging in
            if let paging, let model { paging.apply(to: model) }
        }
        // The first page waits for the width, so it is sized for the grid's columns.
        .task(id: LibraryFilterTaskID(key: key, mediaType: mediaType, isMeasured: width != nil)) {
            host = LibraryPresentation.updated(
                host, for: key, mediaType: mediaType, store: store,
                pinnedFilter: LibraryFilterPresentation.filter(kind: kind, value: value))
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

/// What the filter screen's task runs for: a new key, the library's type once it is known, or the first width.
private struct LibraryFilterTaskID: Hashable {
    let key: BrowseModelKey?
    let mediaType: MediaType?
    let isMeasured: Bool
}

#if DEBUG
    /// Serves ``SampleLibrary``'s books for any query.
    private struct FilterRoutePreviewService: LibraryService {
        struct Failure: Error {}

        func libraries() async throws -> [Library] { [] }
        func library(id: String) async throws -> LibraryWithFilterData { throw Failure() }
        func personalizedShelves(libraryID: String) async throws -> [Shelf] { [] }
        func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<ABSCore.LibraryItem> {
            let books = SampleLibrary.books
            return PagedResults(results: books, total: books.count, limit: query.limit ?? 0, page: query.page ?? 0)
        }
    }

    @MainActor
    private func previewModel(_ kind: LibraryFilterKind, _ value: String, mediaType: MediaType) -> LibraryItemsModel {
        LibraryItemsModel(
            client: FilterRoutePreviewService(), libraryID: SampleLibrary.libraryID, mediaType: mediaType,
            pinnedFilter: LibraryFilterPresentation.filter(kind: kind, value: value), map: { ItemSummary(item: $0) })
    }

    /// The content as the screen shows it once the model exists.
    private struct FilterRoutePreview: View {
        let kind: LibraryFilterKind
        let value: String
        @State var model: LibraryItemsModel

        var body: some View {
            NavigationStack {
                LibraryContent(
                    model: model,
                    placement: LibraryFilterPresentation.placement(kind: kind, value: value, topRoute: nil),
                    messages: LibraryFilterPresentation.messages(for: model)
                )
                .navigationTitle(Text(verbatim: LibraryFilterPresentation.title(kind: kind, value: value)))
            }
            .task { await model.load()?.value }
            .environment(\.serverID, UUID())
            .absBackground()
        }
    }

    #Preview("Narrator in books") {
        FilterRoutePreview(
            kind: .narrators, value: "Stephen Fry", model: previewModel(.narrators, "Stephen Fry", mediaType: .book))
    }

    #Preview("Narrator in podcasts (unsupported), dark") {
        FilterRoutePreview(
            kind: .narrators, value: "Stephen Fry", model: previewModel(.narrators, "Stephen Fry", mediaType: .podcast)
        )
        .preferredColorScheme(.dark)
    }
#endif

#Preview("Narrator, signed out") {
    NavigationStack { LibraryFilterView(kind: .narrators, value: "Stephen Fry") }
        .absBackground()
}

#Preview("Genre, signed out, largest text") {
    NavigationStack { LibraryFilterView(kind: .genres, value: "Science Fiction") }
        .environment(\.dynamicTypeSize, .accessibility3)
        .absBackground()
}
