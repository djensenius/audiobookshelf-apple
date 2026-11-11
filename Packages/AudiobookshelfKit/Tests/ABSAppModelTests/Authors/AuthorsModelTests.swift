import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

private typealias F = SeriesAuthorsFixtures

@MainActor
@Suite struct AuthorsModelTests {
    @Test func loadsAuthorsInServerOrder() async {
        let libraries = Locked<[String]>([])
        let service = FakeSeriesAuthorsService(authorListHandler: { libraryID in
            libraries.value.append(libraryID)
            return [
                Author(id: "a2", name: "Zelazny", imagePath: "/img.jpg", updatedAt: 5, numBooks: 3),
                Author(id: "a1", name: "Asimov"),
            ]
        })
        let model = AuthorsModel(libraryID: "lib1", service: service)

        await model.loadIfNeeded()
        await model.loadIfNeeded()

        #expect(libraries.value == ["lib1"])
        #expect(model.hasLoaded)
        #expect(model.authors.map(\.id) == ["a2", "a1"])
        #expect(
            model.authors.first
                == AuthorSummary(id: "a2", name: "Zelazny", bookCount: 3, hasImage: true, imageUpdatedAt: 5))
        #expect(model.authors.last?.hasImage == false)
    }

    @Test func emptyListIsLoaded() async {
        let model = AuthorsModel(libraryID: "lib", service: FakeSeriesAuthorsService())
        await model.load()
        #expect(model.isEmpty)
    }

    @Test func keepsAuthorsThroughAFailedReload() async {
        let fail = Locked(false)
        let service = FakeSeriesAuthorsService(authorListHandler: { _ in
            if fail.value { throw TestError.offline }
            return [Author(id: "a1", name: "Asimov")]
        })
        let model = AuthorsModel(libraryID: "lib", service: service)

        await model.load()
        fail.value = true
        await model.load()

        #expect(model.authors.map(\.id) == ["a1"])
        #expect(model.error is TestError)
        #expect(!model.isLoading)
    }

    @Test func dropsALateResponse() async throws {
        let gate = GatedCalls<String, [Author]>()
        let model = AuthorsModel(
            libraryID: "lib", service: FakeSeriesAuthorsService(authorListHandler: { try await gate.call($0) }))
        var calls = gate.calls.makeAsyncIterator()

        let first = Task { await model.load() }
        let firstCall = try #require(await calls.next())
        let second = Task { await model.load() }
        let secondCall = try #require(await calls.next())

        secondCall.reply.resume(returning: [Author(id: "new", name: "New")])
        await second.value
        firstCall.reply.resume(returning: [Author(id: "old", name: "Old")])
        await first.value

        #expect(model.authors.map(\.id) == ["new"])
    }
}

@MainActor
@Suite struct AuthorDetailModelTests {
    @Test func loadsAuthorAndPagesBooksWithTheAuthorFilter() async throws {
        let requests = Locked<[SeriesAuthorsRequest]>([])
        let service = FakeSeriesAuthorsService(
            authorDetailHandler: { id in
                AuthorDetailResponse(
                    author: Author(
                        id: id, name: "Asimov", description: "  Wrote a lot.  ", imagePath: "/a.jpg", libraryId: "lib1")
                )
            },
            booksHandler: { libraryID, query in
                requests.value.append(SeriesAuthorsRequest(libraryID: libraryID, query: query))
                return PagedResults(results: [F.book("b1"), F.book("b2")], total: 2, limit: query.limit ?? 0, page: 0)
            })
        let model = AuthorDetailModel(
            authorID: "a1", libraryID: "lib1",
            query: LibraryQuery(sort: "media.metadata.title", filter: .genres("SF"), collapseSeries: true),
            service: service, pageSize: 10)
        #expect(model.phase == .idle)

        await model.loadIfNeeded()

        #expect(model.phase == .loaded)
        let detail = try #require(model.detail)
        #expect(detail.name == "Asimov")
        #expect(detail.summary.hasImage)
        #expect(detail.bio == "  Wrote a lot.  ")
        #expect(detail.libraryID == "lib1")
        #expect(model.books.items.map(\.id) == ["b1", "b2"])
        #expect(model.books.items.first?.title == "Title b1")

        // The given filter is replaced with the author's.
        let request = try #require(requests.value.first)
        #expect(requests.value.count == 1)
        #expect(request.libraryID == "lib1")
        #expect(
            request.query.queryItems.map { "\($0.name)=\($0.value ?? "")" } == [
                "filter=authors.YTE%3D", "sort=media.metadata.title", "desc=0", "collapseseries=1", "limit=10",
                "page=0",
            ])
    }

    @Test func blankBioIsNil() async {
        let service = FakeSeriesAuthorsService(authorDetailHandler: { id in
            AuthorDetailResponse(author: Author(id: id, name: "A", description: " \n"))
        })
        let model = AuthorDetailModel(authorID: "a1", libraryID: "lib", service: service)
        await model.load()
        #expect(model.detail?.bio == nil)
        #expect(model.detail?.libraryID == nil)
        #expect(model.detail?.summary.hasImage == false)
    }

    @Test func dropsALateResponse() async throws {
        let gate = GatedCalls<String, AuthorDetailResponse>()
        let model = AuthorDetailModel(
            authorID: "a1", libraryID: "lib",
            service: FakeSeriesAuthorsService(authorDetailHandler: { try await gate.call($0) }))
        var calls = gate.calls.makeAsyncIterator()

        let first = Task { await model.load() }
        let firstCall = try #require(await calls.next())
        #expect(model.phase == .loading)
        let second = Task { await model.load() }
        let secondCall = try #require(await calls.next())

        secondCall.reply.resume(returning: AuthorDetailResponse(author: Author(id: "a1", name: "New")))
        await second.value
        firstCall.reply.resume(returning: AuthorDetailResponse(author: Author(id: "a1", name: "Old")))
        await first.value

        #expect(model.detail?.name == "New")
    }

    @Test func keepsTheAuthorThroughAFailedReloadAndDropsItOn404() async {
        let failure = Locked<APIError?>(nil)
        let service = FakeSeriesAuthorsService(authorDetailHandler: { id in
            if let error = failure.value { throw error }
            return AuthorDetailResponse(author: Author(id: id, name: "Asimov"))
        })
        let model = AuthorDetailModel(authorID: "a1", libraryID: "lib", service: service)

        await model.load()
        failure.value = .network(.notConnectedToInternet)
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.detail?.name == "Asimov")
        #expect(model.error as? APIError == .network(.notConnectedToInternet))

        failure.value = .notFound
        await model.load()
        #expect(model.phase == .notFound)
        #expect(model.detail == nil)

        // A later non-404 failure doesn't hide that the author is gone.
        failure.value = .timedOut
        await model.load()
        #expect(model.phase == .notFound)
        #expect(model.error as? APIError == .timedOut)
    }

    @Test func cancelledLoadLeavesTheModelIdle() async {
        let service = FakeSeriesAuthorsService(authorDetailHandler: { _ in throw CancellationError() })
        let model = AuthorDetailModel(authorID: "a1", libraryID: "lib", service: service)

        await model.load()

        #expect(model.phase == .idle)
        #expect(model.error == nil)
        #expect(!model.isLoading)
    }

    @Test func refreshReloadsTheAuthorAndTheBooks() async {
        let generation = Locked(0)
        let service = FakeSeriesAuthorsService(
            authorDetailHandler: { id in AuthorDetailResponse(author: Author(id: id, name: "v\(generation.value)")) },
            booksHandler: { _, query in
                PagedResults(
                    results: [F.book("b\(generation.value)")], total: 1, limit: query.limit ?? 0, page: 0)
            })
        let model = AuthorDetailModel(authorID: "a1", libraryID: "lib", service: service)

        await model.loadIfNeeded()
        #expect(model.detail?.name == "v0")
        #expect(model.books.items.map(\.id) == ["b0"])

        generation.value = 1
        await model.refresh()

        #expect(model.detail?.name == "v1")
        #expect(model.books.items.map(\.id) == ["b1"])
    }

    @Test func loadIfNeededLoadsBooksOnceAndRetriesAFailedFirstPage() async {
        let requests = Locked(0)
        let fail = Locked(true)
        let service = FakeSeriesAuthorsService(
            authorDetailHandler: { id in AuthorDetailResponse(author: Author(id: id, name: "A")) },
            booksHandler: { _, query in
                requests.value += 1
                if fail.value { throw TestError.offline }
                return PagedResults(results: [F.book("b1")], total: 1, limit: query.limit ?? 0, page: 0)
            })
        let model = AuthorDetailModel(authorID: "a1", libraryID: "lib", service: service)

        await model.loadIfNeeded()
        #expect(model.books.error is TestError)
        #expect(requests.value == 1)

        fail.value = false
        await model.loadIfNeeded()
        #expect(model.books.items.map(\.id) == ["b1"])
        #expect(requests.value == 2)

        await model.loadIfNeeded()
        #expect(requests.value == 2)
    }

    @Test func failsWithoutAnEarlierLoad() async {
        let service = FakeSeriesAuthorsService(authorDetailHandler: { _ in throw TestError.offline })
        let model = AuthorDetailModel(authorID: "a1", libraryID: "lib", service: service)
        await model.load()
        #expect(model.phase == .failed)
    }

    @Test func authorOfAnotherLibraryMovesTheBooksThere() async {
        let authorRequests = Locked(0)
        let cancelled = Locked<[String]>([])
        let service = FakeSeriesAuthorsService(
            authorDetailHandler: { id in
                authorRequests.value += 1
                return AuthorDetailResponse(author: Author(id: id, name: "A", libraryId: "lib_b"))
            },
            booksHandler: { libraryID, _ in
                guard libraryID == "lib_b" else {
                    // The opened library's page waits until the move cancels it.
                    do { try await Task.sleep(for: .seconds(30)) } catch { cancelled.value.append(libraryID) }
                    throw CancellationError()
                }
                return F.page([F.book("b1"), F.book("b2"), F.book("b3")])
            })
        let model = AuthorDetailModel(authorID: "a1", libraryID: "lib_a", service: service)

        await model.loadIfNeeded()

        #expect(authorRequests.value == 1)
        #expect(model.books.items.map(\.id) == ["b1", "b2", "b3"])
        #expect(model.books.total == 3)
        #expect(cancelled.value == ["lib_a"])
    }
}
