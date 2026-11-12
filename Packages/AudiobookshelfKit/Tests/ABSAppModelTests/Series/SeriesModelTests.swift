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
        let books = (1...5).map { F.book("b\($0)", coverPath: "/covers/\($0).jpg") }
        let service = FakeSeriesAuthorsService(seriesPageHandler: { libraryID, query in
            requests.value.append(SeriesAuthorsRequest(libraryID: libraryID, query: query))
            return PagedResults(
                results: [
                    Series(id: "s1", name: "Barsoom", books: books, totalDuration: 7200),
                    Series(id: "s2", name: "Empty", books: [F.book("c1")], totalDuration: 0),
                ], total: 2, limit: query.limit ?? 0, page: query.page ?? 0)
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
        #expect(list.items.map(\.id) == ["s1", "s2"])
        let barsoom = try #require(list.items.first)
        #expect(barsoom.name == "Barsoom")
        #expect(barsoom.bookCount == 5)
        #expect(barsoom.totalDuration == 7200)
        // At most four covers, from the first books.
        #expect(barsoom.covers.map(\.entityID) == ["b1", "b2", "b3", "b4"])
        // A zero duration is no duration; a book without a cover adds none.
        #expect(list.items.last?.totalDuration == nil)
        #expect(list.items.last?.covers.isEmpty == true)
        #expect(list.reachedEnd)
    }
}

@Suite struct SeriesBookTests {
    @Test func takesTheSequenceOfTheMatchingSeries() {
        let other = Series(id: "other", name: "Other", sequence: "7")
        let mine = Series(id: "s1", name: "Mine", sequence: "3")
        // No list context: the matching metadata series.
        #expect(
            SeriesBook(item: F.book("b1", metadataSeries: [other, mine], context: nil), seriesID: "s1").sequence == "3")
        // A context series that is another series, and no matching metadata series: none.
        #expect(SeriesBook(item: F.book("b2", metadataSeries: [other], context: other), seriesID: "s1").sequence == nil)
        // The context series when it matches.
        #expect(SeriesBook(item: F.book("b3", metadataSeries: [], context: mine), seriesID: "s1").sequence == "3")
    }
}

@MainActor
@Suite struct SeriesDetailModelTests {
    @Test func loadsSeriesThenBooksInServerOrder() async throws {
        let requests = Locked<[SeriesAuthorsRequest]>([])
        let service = FakeSeriesAuthorsService(
            seriesDetailHandler: { id in F.seriesResponse(id, name: "Barsoom", libraryID: "lib-series") },
            booksHandler: { libraryID, query in
                requests.value.append(SeriesAuthorsRequest(libraryID: libraryID, query: query))
                return F.page([
                    F.book("b1", seriesID: "s1", sequence: "1"), F.book("bx", seriesID: "s1"),
                    F.book("b3a", seriesID: "s1", sequence: "3a"), F.book("b2", seriesID: "s1", sequence: "2"),
                ])
            })
        let model = SeriesDetailModel(seriesID: "s1", libraryID: "lib-route", service: service, cache: ProgressCache())
        #expect(model.phase == .idle)

        await model.loadIfNeeded()

        #expect(model.phase == .loaded)
        let detail = try #require(model.detail)
        #expect(detail.name == "Barsoom")
        // The service's order, not re-sorted.
        #expect(detail.books.map(\.id) == ["b1", "bx", "b3a", "b2"])
        #expect(detail.books.map(\.sequence) == ["1", nil, "3a", "2"])
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
                    F.collapsed("sub", firstItemID: "b1", sequence: "1"), F.book("b3", seriesID: "s1", sequence: "3"),
                ])
            })
        let model = SeriesDetailModel(
            seriesID: "s1", libraryID: "lib-route", collapseSeries: true, service: service, cache: ProgressCache())

        await model.load()

        let request = try #require(requests.value.first)
        #expect(request.libraryID == "lib-route")
        #expect(request.query.queryItems.map(\.name) == ["filter", "collapseseries"])
        #expect(model.detail?.books.map(\.id) == ["series-sub", "b3"])
        #expect(model.detail?.books.first?.sequence == "1")
        // The collapsed sub-series isn't a book to continue with.
        #expect(model.continueBook?.id == "b3")
    }

    /// The collapse setting changing reloads a loaded series with the new query, and only then (#319).
    @Test func reloadsWhenTheCollapseSettingChanges() async throws {
        let requests = Locked<[LibraryQuery]>([])
        let service = FakeSeriesAuthorsService(
            seriesDetailHandler: { id in F.seriesResponse(id) },
            booksHandler: { _, query in
                requests.value.append(query)
                return F.page([F.book("b1", seriesID: "s1", sequence: "1")])
            })
        let model = SeriesDetailModel(seriesID: "s1", libraryID: "lib", service: service, cache: ProgressCache())

        // Not loaded: no request, but the next load uses the new value.
        await model.setCollapseSeries(true)
        #expect(requests.value.isEmpty)
        await model.loadIfNeeded()
        #expect(requests.value.map(\.collapseSeries) == [true])

        // Unchanged: no reload.
        await model.setCollapseSeries(true)
        #expect(requests.value.count == 1)

        await model.setCollapseSeries(false)
        #expect(model.collapseSeries == false)
        #expect(requests.value.map(\.collapseSeries) == [true, false])
    }

    @Test func continuesWithTheFirstUnfinishedBookInTheCache() async throws {
        let cache = ProgressCache()
        let service = FakeSeriesAuthorsService(
            seriesDetailHandler: { id in F.seriesResponse(id) },
            booksHandler: { _, _ in
                F.page([
                    F.book("b1", seriesID: "s1", sequence: "1"), F.book("b2", seriesID: "s1", sequence: "2"),
                    F.book("b3", seriesID: "s1", sequence: "3"),
                ])
            })
        let model = SeriesDetailModel(seriesID: "s1", libraryID: "lib", service: service, cache: cache)
        #expect(model.continueBook == nil)

        await model.load()
        #expect(model.continueBook?.id == "b1")

        cache.apply(F.progress("b1", finished: true))
        #expect(model.continueBook?.id == "b2")
        #expect(model.progress(of: try #require(model.detail?.books.first))?.isFinished == true)

        cache.apply(F.progress("b2", finished: true))
        cache.apply(F.progress("b3", finished: true))
        #expect(model.continueBook == nil)
    }

    /// A later book in progress wins over an earlier unfinished one (#319); of several, the one listened to last.
    @Test func continuesWithTheBookInProgress() async throws {
        let cache = ProgressCache()
        let service = FakeSeriesAuthorsService(
            seriesDetailHandler: { id in F.seriesResponse(id) },
            booksHandler: { _, _ in
                F.page([
                    F.book("b1", seriesID: "s1", sequence: "1"), F.book("b2", seriesID: "s1", sequence: "2"),
                    F.book("b3", seriesID: "s1", sequence: "3"),
                    F.book("missing", seriesID: "s1", sequence: "4", isMissing: true),
                ])
            })
        let model = SeriesDetailModel(seriesID: "s1", libraryID: "lib", service: service, cache: cache)
        await model.load()
        // The cache keeps an item's newest progress, so each item's updates get later.
        func started(_ itemID: String, _ fraction: Double, lastUpdate: Int, finished: Bool = false) -> MediaProgress {
            MediaProgress(
                id: "p-\(itemID)", libraryItemId: itemID, progress: fraction, isFinished: finished,
                lastUpdate: lastUpdate)
        }

        // Progress of 0 isn't started: still the first unfinished book.
        cache.apply(started("b3", 0, lastUpdate: 4))
        #expect(model.continueBook?.id == "b1")

        cache.apply(started("b3", 0.4, lastUpdate: 5))
        #expect(model.continueBook?.id == "b3")
        // Of two in progress, the one listened to last.
        cache.apply(started("b2", 0.1, lastUpdate: 9))
        #expect(model.continueBook?.id == "b2")
        cache.apply(started("b3", 0.5, lastUpdate: 10))
        #expect(model.continueBook?.id == "b3")
        // A tie keeps list order.
        cache.apply(started("b2", 0.2, lastUpdate: 10))
        #expect(model.continueBook?.id == "b2")
        // Finished books and unplayable ones are never in progress.
        cache.apply(started("b2", 1, lastUpdate: 20, finished: true))
        cache.apply(started("missing", 0.9, lastUpdate: 99))
        #expect(model.continueBook?.id == "b3")
        cache.apply(started("b3", 1, lastUpdate: 20, finished: true))
        #expect(model.continueBook?.id == "b1")
    }

    @Test func ignoresTheLoadTimeFinishedList() async throws {
        let cache = ProgressCache()
        let service = FakeSeriesAuthorsService(
            seriesDetailHandler: { id in F.seriesResponse(id, finished: ["b1"]) },
            booksHandler: { _, _ in
                F.page([F.book("b1", seriesID: "s1", sequence: "1"), F.book("b2", seriesID: "s1", sequence: "2")])
            })
        let model = SeriesDetailModel(seriesID: "s1", libraryID: "lib", service: service, cache: cache)

        await model.load()
        cache.apply(F.progress("b1", finished: true))
        #expect(model.continueBook?.id == "b2")

        // Progress removed: not started, whatever the series response said.
        cache.remove(libraryItemID: "b1")
        #expect(model.continueBook?.id == "b1")
    }

    @Test func continuesOnlyWithPlayableBooks() async throws {
        let service = FakeSeriesAuthorsService(
            seriesDetailHandler: { id in F.seriesResponse(id) },
            booksHandler: { _, _ in
                F.page([
                    F.book("missing", seriesID: "s1", sequence: "1", isMissing: true),
                    F.book("ebook", seriesID: "s1", sequence: "2", numTracks: 0),
                    F.book("b3", seriesID: "s1", sequence: "3"),
                ])
            })
        let model = SeriesDetailModel(seriesID: "s1", libraryID: "lib", service: service, cache: ProgressCache())

        await model.load()

        #expect(model.detail?.books.count == 3)
        #expect(model.continueBook?.id == "b3")
    }

    @Test func dropsALateSeriesResponse() async throws {
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

    @Test func dropsALateBooksResponse() async throws {
        let gate = GatedCalls<String, PagedResults<LibraryItem>>()
        let service = FakeSeriesAuthorsService(
            seriesDetailHandler: { id in F.seriesResponse(id) },
            booksHandler: { libraryID, _ in try await gate.call(libraryID) })
        let model = SeriesDetailModel(seriesID: "s1", libraryID: "lib", service: service, cache: ProgressCache())
        var calls = gate.calls.makeAsyncIterator()

        let first = Task { await model.load() }
        let firstCall = try #require(await calls.next())
        let second = Task { await model.load() }
        let secondCall = try #require(await calls.next())

        secondCall.reply.resume(returning: F.page([F.book("new")]))
        await second.value
        firstCall.reply.resume(returning: F.page([F.book("old")]))
        await first.value

        #expect(model.detail?.books.map(\.id) == ["new"])
    }

    @Test func cancelledLoadLeavesTheModelIdle() async {
        let service = FakeSeriesAuthorsService(seriesDetailHandler: { _ in throw CancellationError() })
        let model = SeriesDetailModel(seriesID: "s1", libraryID: "lib", service: service, cache: ProgressCache())

        await model.load()

        #expect(model.phase == .idle)
        #expect(model.error == nil)
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

    @Test func seriesNotFoundDropsTheSeriesUntilALoadSucceeds() async {
        let failure = Locked<SeriesLoadFailure?>(nil)
        let service = FakeSeriesAuthorsService(seriesDetailHandler: { id in
            switch failure.value {
            case .notFound: throw APIError.notFound
            case .offline: throw TestError.offline
            case nil: return F.seriesResponse(id)
            }
        })
        let model = SeriesDetailModel(seriesID: "s1", libraryID: "lib", service: service, cache: ProgressCache())

        await model.load()
        #expect(model.phase == .loaded)
        failure.value = .notFound
        await model.load()
        #expect(model.phase == .notFound)
        #expect(model.detail == nil)
        #expect(model.continueBook == nil)

        // A later non-404 failure doesn't hide that the series is gone.
        failure.value = .offline
        await model.load()
        #expect(model.phase == .notFound)
        #expect(model.error is TestError)

        failure.value = nil
        await model.load()
        #expect(model.phase == .loaded)
    }

    @Test func booksNotFoundIsAFailureNotAMissingSeries() async {
        let service = FakeSeriesAuthorsService(
            seriesDetailHandler: { id in F.seriesResponse(id) },
            booksHandler: { _, _ in throw APIError.notFound })
        let model = SeriesDetailModel(seriesID: "s1", libraryID: "lib", service: service, cache: ProgressCache())

        await model.load()

        #expect(model.phase == .failed)
        #expect(model.error as? APIError == .notFound)
    }
}

private enum SeriesLoadFailure: Sendable {
    case notFound, offline
}
