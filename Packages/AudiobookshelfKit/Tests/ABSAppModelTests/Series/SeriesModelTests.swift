import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

private typealias F = SeriesAuthorsFixtures

@MainActor
@Suite struct SeriesListTests {
    @Test func requestsSeriesByNameAscendingAndMapsSummaries() async throws {
        let requests = Locked<[SeriesAuthorsRequest]>([])
        let service = FakeSeriesAuthorsService(seriesPageHandler: { libraryID, query in
            requests.value.append(SeriesAuthorsRequest(libraryID: libraryID, query: query))
            let books = [F.book("b1"), F.book("b2")]
            return PagedResults(
                results: [Series(id: "s1", name: "Barsoom", books: books, totalDuration: 7200)], total: 1,
                limit: query.limit ?? 0, page: query.page ?? 0)
        })
        let list = ItemListModel.series(service: service, libraryID: "lib1", pageSize: 10)

        await list.loadNextPage()?.value

        let request = try #require(requests.value.first)
        #expect(request.libraryID == "lib1")
        #expect(request.query == LibraryQuery(sort: "name", descending: false, page: 0, limit: 10))
        #expect(
            request.query.queryItems.map { "\($0.name)=\($0.value ?? "")" } == [
                "sort=name", "desc=0", "limit=10", "page=0",
            ])
        #expect(
            list.items == [
                SeriesSummary(
                    series: Series(id: "s1", name: "Barsoom", books: [F.book("b1"), F.book("b2")], totalDuration: 7200))
            ])
        #expect(list.items.first?.bookCount == 2)
        #expect(list.reachedEnd)
    }
}

@Suite struct SeriesSequenceTests {
    private func order(_ sequences: [String?]) -> [String] {
        let books = sequences.enumerated().map { index, sequence in
            SeriesBook(
                summary: ItemSummary(id: "i\(index)", itemID: "i\(index)", kind: .book, title: ""), sequence: sequence)
        }
        return SeriesSequence.sorted(books).map(\.id)
    }

    @Test func numericBeforeTextBeforeMissing() {
        // Numbers by value, then text in localized standard order, then missing and blank in input order.
        let sorted = order(["10", nil, "1.5", "Prequel", "2", " ", "1", "Extra 10", "Extra 2"])
        #expect(sorted == ["i6", "i2", "i4", "i0", "i8", "i7", "i3", "i1", "i5"])
    }

    @Test func tiesKeepServerOrder() {
        #expect(order(["2", "1", "2", "1.0", nil, nil]) == ["i1", "i3", "i0", "i2", "i4", "i5"])
    }

    @Test func onlyPlainDecimalsAreNumeric() {
        #expect(SeriesSequence.compare("1e3", "2") == .orderedDescending)
        #expect(SeriesSequence.compare("-1", "0") == .orderedAscending)
        #expect(SeriesSequence.compare("1.2.3", "2") == .orderedDescending)
        #expect(SeriesSequence.compare("09", "10") == .orderedAscending)
    }
}

@MainActor
@Suite struct SeriesDetailModelTests {
    @Test func loadsSeriesThenBooksInSequenceOrder() async throws {
        let requests = Locked<[SeriesAuthorsRequest]>([])
        let service = FakeSeriesAuthorsService(
            seriesDetailHandler: { id in F.seriesResponse(id, name: "Barsoom", libraryID: "lib-series") },
            booksHandler: { libraryID, query in
                requests.value.append(SeriesAuthorsRequest(libraryID: libraryID, query: query))
                return F.page([
                    F.book("b10", seriesID: "s1", sequence: "10"), F.book("bx", seriesID: "s1"),
                    F.book("b2", seriesID: "s1", sequence: "2"), F.book("b1", seriesID: "s1", sequence: "1"),
                ])
            })
        let model = SeriesDetailModel(seriesID: "s1", libraryID: "lib-route", service: service, cache: ProgressCache())
        #expect(model.phase == .idle)

        await model.loadIfNeeded()

        #expect(model.phase == .loaded)
        let detail = try #require(model.detail)
        #expect(detail.name == "Barsoom")
        #expect(detail.books.map(\.id) == ["b1", "b2", "b10", "bx"])
        #expect(detail.books.map(\.sequence) == ["1", "2", "10", nil])
        // The series' own library, the series filter, no sort and no paging.
        let request = try #require(requests.value.first)
        #expect(request.libraryID == "lib-series")
        #expect(request.query == LibraryQuery(filter: .series(id: "s1")))
        #expect(request.query.queryItems.map(\.name) == ["filter"])
        #expect(request.query.queryItems.first?.value == "series.czE%3D")
    }

    @Test func collapsesSeriesWhenAskedAndFallsBackToTheRouteLibrary() async throws {
        let requests = Locked<[SeriesAuthorsRequest]>([])
        let service = FakeSeriesAuthorsService(
            seriesDetailHandler: { id in F.seriesResponse(id, libraryID: nil) },
            booksHandler: { libraryID, query in
                requests.value.append(SeriesAuthorsRequest(libraryID: libraryID, query: query))
                return F.page([
                    F.book("b3", seriesID: "s1", sequence: "3"), F.collapsed("sub", firstItemID: "b1", sequence: "1"),
                ])
            })
        let model = SeriesDetailModel(
            seriesID: "s1", libraryID: "lib-route", collapseSeries: true, service: service, cache: ProgressCache())

        await model.load()

        let request = try #require(requests.value.first)
        #expect(request.libraryID == "lib-route")
        #expect(request.query.queryItems.map(\.name) == ["filter", "collapseseries"])
        #expect(model.detail?.books.map(\.id) == ["series-sub", "b3"])
        // The collapsed sub-series isn't a book to continue with.
        #expect(model.continueBook?.id == "b3")
    }

    @Test func continuesWithTheFirstUnfinishedBook() async throws {
        let cache = ProgressCache()
        let service = FakeSeriesAuthorsService(
            seriesDetailHandler: { id in F.seriesResponse(id, finished: ["b2"]) },
            booksHandler: { _, _ in
                F.page([
                    F.book("b3", seriesID: "s1", sequence: "3"), F.book("b1", seriesID: "s1", sequence: "1"),
                    F.book("b2", seriesID: "s1", sequence: "2"),
                ])
            })
        let model = SeriesDetailModel(seriesID: "s1", libraryID: "lib", service: service, cache: cache)
        #expect(model.continueBook == nil)

        await model.load()
        #expect(model.continueBook?.id == "b1")

        // b1 finished in the cache; b2 is finished in the series' snapshot.
        cache.apply(F.progress("b1", finished: true))
        #expect(model.continueBook?.id == "b3")
        #expect(model.progress(of: try #require(model.detail?.books.first))?.isFinished == true)

        // The cache wins over the snapshot.
        cache.apply(F.progress("b2", finished: false))
        #expect(model.continueBook?.id == "b2")

        cache.apply(F.progress("b2", finished: true))
        cache.apply(F.progress("b3", finished: true))
        #expect(model.continueBook == nil)
    }

    @Test func dropsALateResponse() async throws {
        let gate = GatedCalls<String, SeriesDetailResponse>()
        let service = FakeSeriesAuthorsService(
            seriesDetailHandler: { id in try await gate.call(id) },
            booksHandler: { _, _ in F.page([F.book("b1", seriesID: "s1", sequence: "1")]) })
        let model = SeriesDetailModel(seriesID: "s1", libraryID: "lib", service: service, cache: ProgressCache())
        var calls = gate.calls.makeAsyncIterator()

        let first = Task { await model.load() }
        let firstCall = try #require(await calls.next())
        #expect(model.phase == .loading)
        let second = Task { await model.load() }
        let secondCall = try #require(await calls.next())

        secondCall.reply.resume(returning: F.seriesResponse("s1", name: "New"))
        await second.value
        firstCall.reply.resume(returning: F.seriesResponse("s1", name: "Old"))
        await first.value

        #expect(model.detail?.name == "New")
        #expect(!model.isLoading)
    }

    @Test func keepsTheSeriesThroughAFailedReload() async throws {
        let fail = Locked(false)
        let service = FakeSeriesAuthorsService(
            seriesDetailHandler: { id in F.seriesResponse(id) },
            booksHandler: { _, _ in
                if fail.value { throw TestError.offline }
                return F.page([F.book("b1", seriesID: "s1", sequence: "1")])
            })
        let model = SeriesDetailModel(seriesID: "s1", libraryID: "lib", service: service, cache: ProgressCache())

        await model.load()
        fail.value = true
        await model.load()

        #expect(model.phase == .loaded)
        #expect(model.detail?.books.map(\.id) == ["b1"])
        #expect(model.error is TestError)
    }

    @Test func failsWithoutAnEarlierLoad() async {
        let service = FakeSeriesAuthorsService(seriesDetailHandler: { _ in throw TestError.offline })
        let model = SeriesDetailModel(seriesID: "s1", libraryID: "lib", service: service, cache: ProgressCache())

        await model.load()

        #expect(model.phase == .failed)
        #expect(model.error is TestError)
    }

    @Test func notFoundDropsTheSeries() async {
        let missing = Locked(false)
        let service = FakeSeriesAuthorsService(seriesDetailHandler: { id in
            if missing.value { throw APIError.notFound }
            return F.seriesResponse(id)
        })
        let model = SeriesDetailModel(seriesID: "s1", libraryID: "lib", service: service, cache: ProgressCache())

        await model.load()
        #expect(model.phase == .loaded)
        missing.value = true
        await model.load()

        #expect(model.phase == .notFound)
        #expect(model.detail == nil)
        #expect(model.continueBook == nil)
    }
}
