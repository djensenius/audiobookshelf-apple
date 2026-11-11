import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

/// A ``SeriesAuthorsService`` whose responses come from closures.
struct FakeSeriesAuthorsService: SeriesAuthorsService {
    var seriesPageHandler: @Sendable (String, LibraryQuery) async throws -> PagedResults<Series> = { _, query in
        PagedResults(results: [], total: 0, limit: query.limit ?? 0, page: query.page ?? 0)
    }
    var authorListHandler: @Sendable (String) async throws -> [Author] = { _ in [] }
    var seriesDetailHandler: @Sendable (String) async throws -> SeriesDetailResponse = { _ in
        throw TestError.unexpected
    }
    var authorDetailHandler: @Sendable (String) async throws -> AuthorDetailResponse = { _ in
        throw TestError.unexpected
    }
    var booksHandler: @Sendable (String, LibraryQuery) async throws -> PagedResults<LibraryItem> = { _, query in
        PagedResults(results: [], total: 0, limit: query.limit ?? 0, page: query.page ?? 0)
    }

    func seriesPage(libraryID: String, query: LibraryQuery) async throws -> PagedResults<Series> {
        try await seriesPageHandler(libraryID, query)
    }
    func authorList(libraryID: String) async throws -> [Author] { try await authorListHandler(libraryID) }
    func seriesDetail(id: String) async throws -> SeriesDetailResponse { try await seriesDetailHandler(id) }
    func authorDetail(id: String) async throws -> AuthorDetailResponse { try await authorDetailHandler(id) }
    func filteredBooksPage(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> {
        try await booksHandler(libraryID, query)
    }
}

/// A recorded `filteredBooksPage` or `seriesPage` request.
struct SeriesAuthorsRequest: Sendable, Equatable {
    let libraryID: String
    let query: LibraryQuery
}

enum SeriesAuthorsFixtures {
    /// A book in the series `seriesID` (if any) at `sequence`, listed with that series as context.
    static func book(_ id: String, seriesID: String? = nil, sequence: String? = nil) -> LibraryItem {
        let series = seriesID.map { Series(id: $0, name: "Series \($0)", sequence: sequence) }
        let metadata = BookMetadata(title: "Title \(id)", series: series.map { [$0] })
        return LibraryItem(
            id: id, libraryId: "lib", mediaType: .book,
            media: .book(Book(id: "book-\(id)", metadata: metadata, numTracks: 1)), series: series)
    }

    /// A collapsed sub-series standing in for its first book `firstItemID`.
    static func collapsed(_ seriesID: String, firstItemID: String, sequence: String?) -> LibraryItem {
        LibraryItem(
            id: firstItemID, libraryId: "lib", mediaType: .book,
            media: .book(Book(id: "book-\(firstItemID)", metadata: BookMetadata(title: "Title"), numTracks: 1)),
            collapsedSeries: CollapsedSeries(id: seriesID, name: "Sub \(seriesID)", sequence: sequence, numBooks: 2))
    }

    static func seriesResponse(
        _ id: String, name: String? = nil, libraryID: String? = "lib", finished: [String] = []
    ) -> SeriesDetailResponse {
        SeriesDetailResponse(
            series: Series(id: id, name: name ?? "Series \(id)", libraryId: libraryID),
            progress: SeriesProgress(libraryItemIds: [], libraryItemIdsFinished: finished, isFinished: false))
    }

    static func page<Element: Sendable>(_ results: [Element]) -> PagedResults<Element> {
        PagedResults(results: results, total: results.count, limit: 0, page: 0)
    }

    static func progress(_ itemID: String, finished: Bool) -> MediaProgress {
        MediaProgress(id: "p-\(itemID)", libraryItemId: itemID, isFinished: finished, lastUpdate: 1)
    }
}
