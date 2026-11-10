import ABSAPI
import ABSCore
import Foundation
import Synchronization
import Testing

@testable import ABSAppModel

private typealias Model = ItemListModel<String, TestItem>

private struct PageRequest: Sendable, Equatable {
    let query: String
    let page: Int
    let limit: Int
}

/// Serves `pages` in order of the requested page index and records every request.
private final class PageServer: Sendable {
    let pages: [[TestItem]]
    let total: Int?
    let requests = Mutex<[PageRequest]>([])

    init(pages: [[TestItem]], total: Int?) {
        self.pages = pages
        self.total = total
    }

    func fetch(_ query: String, _ page: Int, _ limit: Int) -> PagedResults<TestItem> {
        requests.withLock { $0.append(PageRequest(query: query, page: page, limit: limit)) }
        let results = page < pages.count ? pages[page] : []
        return PagedResults(results: results, total: total, limit: limit, page: page)
    }

    var requestedPages: [Int] { requests.withLock { $0.map(\.page) } }
}

@MainActor
private func makeModel(_ server: PageServer, query: String = "a", pageSize: Int = 20, threshold: Int = 5) -> Model {
    Model(query: query, pageSize: pageSize, prefetchThreshold: threshold) { query, page, limit in
        server.fetch(query, page, limit)
    }
}

@MainActor
@Suite struct ItemListModelTests {
    @Test func appendsPagesInOrder() async {
        let server = PageServer(pages: [items(1...20), items(21...40), items(41...45)], total: 45)
        let model = makeModel(server)

        await model.loadNextPage()?.value
        #expect(model.items == items(1...20))
        #expect(model.total == 45)
        #expect(!model.reachedEnd)

        await model.loadNextPage()?.value
        #expect(model.items == items(1...40))

        await model.loadNextPage()?.value
        #expect(model.items == items(1...45))
        #expect(model.reachedEnd)
        #expect(server.requests.withLock { $0 }.allSatisfy { $0.query == "a" && $0.limit == 20 })
    }

    @Test func stopsAtTheTotal() async {
        let server = PageServer(pages: [items(1...20), items(21...40), items(41...60)], total: 40)
        let model = makeModel(server)

        await model.loadNextPage()?.value
        await model.loadNextPage()?.value
        #expect(model.reachedEnd)
        #expect(model.loadNextPage() == nil)
        model.itemAppeared(at: 39)
        #expect(!model.isLoading)
        #expect(server.requestedPages == [0, 1])
        #expect(model.items.count == 40)
    }

    @Test func stopsAtAShortPageWithoutTotal() async {
        let server = PageServer(pages: [items(1...20), items(21...25)], total: nil)
        let model = makeModel(server)

        await model.loadNextPage()?.value
        #expect(!model.reachedEnd)
        await model.loadNextPage()?.value
        #expect(model.reachedEnd)
        #expect(model.loadNextPage() == nil)
        #expect(server.requestedPages == [0, 1])
    }

    @Test func stopsAtAnEmptyPage() async {
        // The total says there is more, but the server has nothing left (items were deleted).
        let server = PageServer(pages: [items(1...20)], total: 30)
        let model = makeModel(server)

        await model.loadNextPage()?.value
        await model.loadNextPage()?.value
        #expect(model.reachedEnd)
        #expect(model.items.count == 20)
    }

    @Test func prefetchesNearTheEnd() async {
        let server = PageServer(pages: [items(1...20), items(21...40)], total: 40)
        let model = makeModel(server, threshold: 5)
        await model.loadNextPage()?.value

        model.itemAppeared(at: 14)
        #expect(!model.isLoading)
        model.itemAppeared(id: "item15")  // index 14
        #expect(!model.isLoading)

        model.itemAppeared(at: 15)
        #expect(model.isLoading)
        // Further appearances join the page in flight instead of requesting another.
        model.itemAppeared(at: 19)
        await model.loadNextPage()?.value
        #expect(server.requestedPages == [0, 1])
        #expect(model.items == items(1...40))
    }

    @Test func skipsDuplicateItems() async {
        // An item was added on the server between pages, shifting item 20 onto page 1.
        let server = PageServer(pages: [items(1...20), items(20...39)], total: 40)
        let model = makeModel(server)

        await model.loadNextPage()?.value
        await model.loadNextPage()?.value
        #expect(model.items == items(1...39))
        #expect(Set(model.items.map(\.id)).count == model.items.count)
        // The end is detected from the results received, duplicates included.
        #expect(model.reachedEnd)
    }

    @Test func queryChangeResetsToTheFirstPage() async {
        let server = PageServer(pages: [items(1...20), items(21...40)], total: 40)
        let model = makeModel(server)
        await model.loadNextPage()?.value
        await model.loadNextPage()?.value
        #expect(model.reachedEnd)

        #expect(model.setQuery("a") == nil)

        let reload = model.setQuery("b")
        #expect(model.items.isEmpty)
        #expect(model.total == nil)
        #expect(!model.reachedEnd)
        await reload?.value
        #expect(model.query == "b")
        #expect(model.items == items(1...20))
        #expect(server.requests.withLock { $0.last } == PageRequest(query: "b", page: 0, limit: 20))
    }

    @Test func queryChangeDropsTheStalePage() async throws {
        let gate = GatedCalls<PageRequest, PagedResults<TestItem>>()
        let model = Model(query: "a", pageSize: 2) { query, page, limit in
            try await gate.call(PageRequest(query: query, page: page, limit: limit))
        }
        var calls = gate.calls.makeAsyncIterator()

        let staleLoad = try #require(model.loadNextPage())
        let stale = try #require(await calls.next())
        #expect(stale.request == PageRequest(query: "a", page: 0, limit: 2))

        let freshLoad = try #require(model.setQuery("b"))
        #expect(staleLoad.isCancelled)
        let fresh = try #require(await calls.next())
        #expect(fresh.request == PageRequest(query: "b", page: 0, limit: 2))

        // The old query's page arrives after the reset and must not be appended.
        stale.reply.resume(returning: PagedResults(results: items(1...2, prefix: "a"), total: 10, limit: 2, page: 0))
        await staleLoad.value
        #expect(model.items.isEmpty)
        #expect(model.total == nil)
        #expect(model.isLoading)

        fresh.reply.resume(returning: PagedResults(results: items(1...1, prefix: "b"), total: 1, limit: 2, page: 0))
        await freshLoad.value
        #expect(model.items == items(1...1, prefix: "b"))
        #expect(model.total == 1)
        #expect(model.reachedEnd)
        #expect(!model.isLoading)
    }

    @Test func failedPageIsRetriedExplicitly() async {
        let fail = Locked(true)
        let model = Model(query: "a", pageSize: 2) { _, page, limit in
            if fail.value { throw TestError.offline }
            return PagedResults(results: items(1...2), total: 4, limit: limit, page: page)
        }

        await model.loadNextPage()?.value
        #expect(model.error is TestError)
        #expect(model.items.isEmpty)
        model.itemAppeared(at: 0)
        #expect(!model.isLoading)

        fail.value = false
        await model.loadNextPage()?.value
        #expect(model.error == nil)
        #expect(model.items == items(1...2))
    }

    @Test func libraryItemsSetsPageAndLimit() async {
        let queries = Locked<[LibraryQuery]>([])
        var service = FakeLibraryService()
        service.itemsHandler = { libraryID, query in
            #expect(libraryID == "lib")
            queries.value.append(query)
            return PagedResults(results: [], total: 0, limit: query.limit ?? 0, page: query.page ?? 0)
        }
        let filter = LibraryQuery(sort: "addedAt", descending: true)
        let model = ItemListModel(client: service, libraryID: "lib", query: filter, pageSize: 50)

        await model.loadNextPage()?.value
        #expect(queries.value == [LibraryQuery(sort: "addedAt", descending: true, page: 0, limit: 50)])
        #expect(model.reachedEnd)
    }
}
