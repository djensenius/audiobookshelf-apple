#if DEBUG
    import ABSAPI
    import ABSAppModel
    import ABSCore
    import ABSUI
    import Foundation

    /// Serves ``SampleLibrary``, or fails every request when `fails`.
    struct SeriesAuthorsPreviewService: SeriesAuthorsService {
        struct Failure: Error {}

        var fails = false

        /// A series description and author bio long enough to collapse.
        static let text = """
            Edgar Rice Burroughs wrote adventure stories set on Mars, Venus and in the jungles of Africa. \
            The Barsoom series follows John Carter, a Civil War veteran who wakes up on a dying Mars and \
            fights his way through its cities, deserts and dried-up seas.
            """

        func seriesPage(libraryID: String, query: LibraryQuery) async throws -> PagedResults<Series> {
            try check()
            return PagedResults(
                results: SampleLibrary.series, total: SampleLibrary.series.count, limit: query.limit ?? 0,
                page: query.page ?? 0)
        }

        func authorList(libraryID: String) async throws -> [Author] {
            try check()
            return SampleLibrary.authors
        }

        func seriesDetail(id: String) async throws -> SeriesDetailResponse {
            try check()
            return SeriesDetailResponse(
                series: Series(id: id, name: "Barsoom", description: Self.text, libraryId: SampleLibrary.libraryID))
        }

        func authorDetail(id: String) async throws -> AuthorDetailResponse {
            try check()
            return AuthorDetailResponse(
                author: Author(
                    id: id, name: "Edgar Rice Burroughs", description: Self.text, libraryId: SampleLibrary.libraryID))
        }

        func filteredBooksPage(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> {
            try check()
            let books = [SampleLibrary.princessOfMars, SampleLibrary.godsOfMars, SampleLibrary.warlordOfMars]
                .enumerated().map { Self.listed($1, in: "ser_barsoom", sequence: "\($0 + 1)") }
            return PagedResults(results: books, total: books.count, limit: query.limit ?? 0, page: query.page ?? 0)
        }

        /// `item` as a series-filtered list sends it: with the series and the item's sequence.
        static func listed(_ item: LibraryItem, in seriesID: String, sequence: String) -> LibraryItem {
            LibraryItem(
                id: item.id, libraryId: item.libraryId, updatedAt: item.updatedAt, isMissing: item.isMissing,
                mediaType: item.mediaType, media: item.media,
                series: Series(id: seriesID, name: "Barsoom", sequence: sequence))
        }

        private func check() throws {
            if fails { throw Failure() }
        }
    }

    /// Fixture models for the series and author previews, served from ``SampleLibrary``.
    @MainActor
    enum SeriesAuthorsPreviewData {
        /// The first Barsoom book is finished, so Continue Series offers the second.
        static let progress: ProgressCache = {
            let cache = ProgressCache()
            cache.apply(
                MediaProgress(
                    id: "mp_1", libraryItemId: SampleLibrary.princessOfMars.id, progress: 1, isFinished: true))
            cache.apply(MediaProgress(id: "mp_2", libraryItemId: SampleLibrary.godsOfMars.id, progress: 0.3))
            return cache
        }()

        static let progressReader = BrowsePresentation.progressReader(progress)

        static func seriesList(fails: Bool = false) -> SeriesListModel {
            .series(service: SeriesAuthorsPreviewService(fails: fails), libraryID: SampleLibrary.libraryID)
        }

        static func seriesDetail(fails: Bool = false) -> SeriesDetailModel {
            SeriesDetailModel(
                seriesID: "ser_barsoom", libraryID: SampleLibrary.libraryID,
                service: SeriesAuthorsPreviewService(fails: fails), cache: progress)
        }

        static func authors(fails: Bool = false) -> AuthorsModel {
            AuthorsModel(libraryID: SampleLibrary.libraryID, service: SeriesAuthorsPreviewService(fails: fails))
        }

        static func authorDetail(fails: Bool = false) -> AuthorDetailModel {
            AuthorDetailModel(
                authorID: "aut_burroughs", libraryID: SampleLibrary.libraryID,
                service: SeriesAuthorsPreviewService(fails: fails))
        }
    }
#endif
