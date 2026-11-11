import ABSAPI
import ABSCore
import Foundation

/// The series and author endpoints the series and author screens use. `APIClient` conforms;
/// tests use fakes.
public protocol SeriesAuthorsService: Sendable {
    /// `GET /api/libraries/:id/series`: one page of series.
    func seriesPage(libraryID: String, query: LibraryQuery) async throws -> PagedResults<Series>
    /// `GET /api/libraries/:id/authors`: every author, unpaged, in server order.
    func authorList(libraryID: String) async throws -> [Author]
    /// `GET /api/series/:id?include=progress`: the series and the user's aggregate progress, no books.
    func seriesDetail(id: String) async throws -> SeriesDetailResponse
    /// `GET /api/authors/:id?include=items,series`.
    func authorDetail(id: String) async throws -> AuthorDetailResponse
    /// `GET /api/libraries/:id/items` with a filter, for the books of a series or an author.
    func filteredBooksPage(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem>
}

extension APIClient: SeriesAuthorsService {
    public func seriesPage(libraryID: String, query: LibraryQuery) async throws -> PagedResults<Series> {
        try await send(LibraryEndpoints.series(libraryID: libraryID, query: query))
    }

    public func authorList(libraryID: String) async throws -> [Author] {
        try await send(LibraryEndpoints.authors(libraryID: libraryID)).authors
    }

    public func seriesDetail(id: String) async throws -> SeriesDetailResponse {
        try await send(SeriesEndpoints.detail(id: id))
    }

    public func authorDetail(id: String) async throws -> AuthorDetailResponse {
        try await send(AuthorEndpoints.author(id: id))
    }

    public func filteredBooksPage(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> {
        try await send(LibraryEndpoints.items(libraryID: libraryID, query: query))
    }
}

extension ItemListModel where Query == String, Item == SeriesSummary {
    /// The series of the library `libraryID`, the model's query, sorted by name ascending like
    /// the legacy `LazyBookshelf.vue` (`sort=name&desc=0`). ``setQuery(_:)`` with another library
    /// ID switches libraries.
    ///
    /// Like every ``ItemListModel``, it belongs to one account: views create it per account
    /// identity and recreate it when the identity changes.
    public static func series(
        service: any SeriesAuthorsService, libraryID: String, pageSize: Int = 20, prefetchThreshold: Int = 5,
        connectionKey: LibraryConnectionKey? = nil
    ) -> ItemListModel {
        ItemListModel(
            query: libraryID, pageSize: pageSize, prefetchThreshold: prefetchThreshold, connectionKey: connectionKey
        ) { libraryID, page, limit in
            let query = LibraryQuery(sort: "name", descending: false, page: page, limit: limit)
            return try await service.seriesPage(libraryID: libraryID, query: query).map(SeriesSummary.init(series:))
        }
    }
}

extension ItemListModel where Query == LibraryQuery, Item == ItemSummary {
    /// The library's items matching `query`, mapped to ``ItemSummary``. The query's `page` and
    /// `limit` are set by the model.
    static func filteredBooks(
        service: any SeriesAuthorsService, libraryID: String, query: LibraryQuery, pageSize: Int,
        prefetchThreshold: Int, connectionKey: LibraryConnectionKey?
    ) -> ItemListModel {
        ItemListModel(
            query: query, pageSize: pageSize, prefetchThreshold: prefetchThreshold, connectionKey: connectionKey
        ) { query, page, limit in
            var query = query
            query.page = page
            query.limit = limit
            return try await service.filteredBooksPage(libraryID: libraryID, query: query).map { ItemSummary(item: $0) }
        }
    }
}
