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

/// Serves pages whose rows partly failed to decode: `rawCounts[page]` rows were sent and
/// `pages[page]` survived.
@MainActor
private func makeLossyModel(
    pages: [[TestItem]], rawCounts: [Int], total: Int?, pageSize: Int = 4, requests: Locked<[Int]>
) -> Model {
    Model(query: "a", pageSize: pageSize, prefetchThreshold: 1) { _, page, limit in
        requests.value.append(page)
        guard page < pages.count else { return PagedResults(results: [], total: total, limit: limit, page: page) }
        return PagedResults(results: pages[page], total: total, limit: limit, page: page, rawCount: rawCounts[page])
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

    @Test func pagingChangesApplyWithoutBreakingThePageOffsets() async {
        // Serves items by offset, so a page size mismatch between pages would skip or repeat items.
        let all = items(1...100)
        let limits = Mutex<[Int]>([])
        let model = Model(query: "a") { _, page, limit in
            limits.withLock { $0.append(limit) }
            let results = Array(all.dropFirst(page * limit).prefix(limit))
            return PagedResults(results: results, total: all.count, limit: limit, page: page)
        }
        // Nothing requested yet: both apply now.
        model.setPaging(pageSize: 40, prefetchThreshold: 20)
        #expect(model.pageSize == 40)
        await model.loadNextPage()?.value
        #expect(model.items == items(1...40))
        model.itemAppeared(at: 19)
        #expect(!model.isLoading)

        // Mid-list, the threshold applies to the next appearance; the page size waits for a restart.
        model.setPaging(pageSize: 30, prefetchThreshold: 30)
        #expect(model.pageSize == 40)
        model.itemAppeared(at: 10)
        #expect(model.isLoading)
        await model.loadNextPage()?.value
        #expect(model.items == items(1...80))

        await model.refresh()?.value
        #expect(model.pageSize == 30)
        #expect(model.items == items(1...30))
        #expect(limits.withLock { $0 } == [40, 40, 30])

        // Setting the current size back drops the waiting one.
        model.setPaging(pageSize: 50, prefetchThreshold: 5)
        model.setPaging(pageSize: 30, prefetchThreshold: 5)
        await model.reset()?.value
        #expect(model.pageSize == 30)
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

    @Test func staleFailureAfterAResetIsDropped() async throws {
        let gate = GatedCalls<PageRequest, PagedResults<TestItem>>()
        let model = Model(query: "a", pageSize: 2) { query, page, limit in
            try await gate.call(PageRequest(query: query, page: page, limit: limit))
        }
        var calls = gate.calls.makeAsyncIterator()

        let staleLoad = try #require(model.loadNextPage())
        let stale = try #require(await calls.next())
        let freshLoad = try #require(model.setQuery("b"))
        let fresh = try #require(await calls.next())

        stale.reply.resume(throwing: TestError.offline)
        await staleLoad.value
        #expect(model.error == nil)
        #expect(model.isLoading)

        fresh.reply.resume(returning: PagedResults(results: items(1...2), total: 2, limit: 2, page: 0))
        await freshLoad.value
        #expect(model.error == nil)
        #expect(model.items == items(1...2))
    }

    @Test func resetClearsAnError() async {
        let fail = Locked(true)
        let model = Model(query: "a", pageSize: 2) { _, page, limit in
            if fail.value { throw TestError.offline }
            return PagedResults(results: items(1...2), total: 2, limit: limit, page: page)
        }
        await model.loadNextPage()?.value
        #expect(model.error is TestError)

        fail.value = false
        let reload = model.reset()
        #expect(model.error == nil)
        #expect(model.isLoading)
        await reload?.value
        #expect(model.items == items(1...2))
        #expect(model.reachedEnd)
    }

    @Test func refreshKeepsItemsUntilTheFirstPage() async throws {
        let gate = GatedCalls<PageRequest, PagedResults<TestItem>>()
        let model = Model(query: "a", pageSize: 2) { query, page, limit in
            try await gate.call(PageRequest(query: query, page: page, limit: limit))
        }
        var calls = gate.calls.makeAsyncIterator()
        for page in 0..<2 {
            let load = try #require(model.loadNextPage())
            let call = try #require(await calls.next())
            let results = items((page * 2 + 1)...(page * 2 + 2))
            call.reply.resume(returning: PagedResults(results: results, total: 6, limit: 2, page: page))
            await load.value
        }
        #expect(model.items == items(1...4))

        let refresh = try #require(model.refresh())
        let call = try #require(await calls.next())
        #expect(call.request == PageRequest(query: "a", page: 0, limit: 2))
        #expect(model.items == items(1...4))
        #expect(model.isLoading)
        // Appearing items join the reload instead of requesting page 2 of the old list.
        model.itemAppeared(at: 3)

        call.reply.resume(returning: PagedResults(results: items(10...11), total: 4, limit: 2, page: 0))
        await refresh.value
        #expect(model.items == items(10...11))
        #expect(model.total == 4)

        let next = try #require(model.loadNextPage())
        let nextCall = try #require(await calls.next())
        #expect(nextCall.request.page == 1)
        nextCall.reply.resume(returning: PagedResults(results: items(12...13), total: 4, limit: 2, page: 1))
        await next.value
        #expect(model.items == items(10...13))
        #expect(model.reachedEnd)
    }

    @Test func cancelledRefreshContinuesTheOldList() async throws {
        let gate = GatedCalls<PageRequest, PagedResults<TestItem>>()
        let model = Model(query: "a", pageSize: 2) { query, page, limit in
            try await gate.call(PageRequest(query: query, page: page, limit: limit))
        }
        var calls = gate.calls.makeAsyncIterator()
        for page in 0..<2 {
            let load = try #require(model.loadNextPage())
            let call = try #require(await calls.next())
            let results = items((page * 2 + 1)...(page * 2 + 2))
            call.reply.resume(returning: PagedResults(results: results, total: 6, limit: 2, page: page))
            await load.value
        }

        let refresh = try #require(model.refresh())
        let call = try #require(await calls.next())
        #expect(call.request.page == 0)
        call.reply.resume(throwing: CancellationError())
        await refresh.value
        #expect(model.items == items(1...4))
        #expect(model.error == nil)
        #expect(!model.isLoading)
        #expect(model.total == 6)

        // A later scroll loads the old list's next page, not page 0.
        model.itemAppeared(at: 3)
        let next = try #require(model.loadNextPage())
        let nextCall = try #require(await calls.next())
        #expect(nextCall.request.page == 2)
        nextCall.reply.resume(returning: PagedResults(results: items(5...6), total: 6, limit: 2, page: 2))
        await next.value
        #expect(model.items == items(1...6))
        #expect(model.reachedEnd)
    }

    @Test func cancelledRefreshOfACompleteListNeverAppendsTheNewFirstPage() async throws {
        let gate = GatedCalls<PageRequest, PagedResults<TestItem>>()
        let model = Model(query: "a", pageSize: 2) { query, page, limit in
            try await gate.call(PageRequest(query: query, page: page, limit: limit))
        }
        var calls = gate.calls.makeAsyncIterator()
        let old = [TestItem(id: "A"), TestItem(id: "B")]
        let new = [TestItem(id: "C"), TestItem(id: "D")]
        let first = try #require(model.loadNextPage())
        try #require(await calls.next()).reply.resume(
            returning: PagedResults(results: old, total: 2, limit: 2, page: 0))
        await first.value
        #expect(model.reachedEnd)

        let cancelled = try #require(model.refresh())
        try #require(await calls.next()).reply.resume(throwing: CancellationError())
        await cancelled.value
        #expect(model.items == old)
        #expect(model.reachedEnd)
        #expect(model.loadNextPage() == nil)

        // Retrying the refresh replaces the list.
        let retry = try #require(model.refresh())
        let retryCall = try #require(await calls.next())
        #expect(retryCall.request.page == 0)
        retryCall.reply.resume(returning: PagedResults(results: new, total: 2, limit: 2, page: 0))
        await retry.value
        #expect(model.items == new)
        #expect(model.reachedEnd)
    }

    @Test func failedRefreshRollsBackAndReportsTheError() async throws {
        let gate = GatedCalls<PageRequest, PagedResults<TestItem>>()
        let model = Model(query: "a", pageSize: 2) { query, page, limit in
            try await gate.call(PageRequest(query: query, page: page, limit: limit))
        }
        var calls = gate.calls.makeAsyncIterator()
        let first = try #require(model.loadNextPage())
        try #require(await calls.next()).reply.resume(
            returning: PagedResults(results: items(1...2), total: 4, limit: 2, page: 0))
        await first.value

        // A refresh replacing an unfinished one keeps the first snapshot.
        let superseded = try #require(model.refresh())
        let supersededCall = try #require(await calls.next())
        let failed = try #require(model.refresh())
        let failedCall = try #require(await calls.next())
        supersededCall.reply.resume(returning: PagedResults(results: items(7...8), total: 2, limit: 2, page: 0))
        await superseded.value
        failedCall.reply.resume(throwing: TestError.offline)
        await failed.value
        #expect(model.error is TestError)
        #expect(model.items == items(1...2))
        #expect(model.total == 4)
        #expect(!model.reachedEnd)

        // Retrying the page continues the old list.
        let next = try #require(model.loadNextPage())
        let nextCall = try #require(await calls.next())
        #expect(nextCall.request.page == 1)
        nextCall.reply.resume(returning: PagedResults(results: items(3...4), total: 4, limit: 2, page: 1))
        await next.value
        #expect(model.items == items(1...4))
        #expect(model.reachedEnd)
    }

    @Test func releasingTheModelCancelsThePageInFlight() async throws {
        let gate = GatedCalls<PageRequest, PagedResults<TestItem>>()
        var model: Model? = Model(query: "a", pageSize: 2) { query, page, limit in
            try await gate.call(PageRequest(query: query, page: page, limit: limit))
        }
        weak let released = model
        var calls = gate.calls.makeAsyncIterator()
        let load = try #require(model?.loadNextPage())
        let call = try #require(await calls.next())

        model = nil
        #expect(released == nil)
        #expect(load.isCancelled)

        call.reply.resume(returning: PagedResults(results: items(1...2), total: 2, limit: 2, page: 0))
        await load.value
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
    @Test func malformedRowsDoNotEndTheList() async {
        for total in [12, nil] as [Int?] {
            let requests = Locked<[Int]>([])
            // Page 0 is full but one row failed to decode; page 1 is entirely malformed.
            let model = makeLossyModel(
                pages: [items(1...3), [], items(9...12)], rawCounts: [4, 4, 4], total: total, requests: requests)

            await model.loadNextPage()?.value
            #expect(model.items == items(1...3))
            #expect(!model.reachedEnd)

            await model.loadNextPage()?.value
            // The empty page started the next load by itself, which may already have finished;
            // this awaits it without starting another.
            while model.isLoading, let task = model.loadNextPage() { await task.value }
            #expect(requests.value == [0, 1, 2])
            #expect(model.items == items(1...3) + items(9...12))
            if total != nil { #expect(model.reachedEnd) }
        }
    }

    @Test func pagesWithoutDisplayableItemsAdvanceAutomatically() async {
        let requests = Locked<[Int]>([])
        let model = makeLossyModel(
            pages: [[], [], items(1...2)], rawCounts: [4, 4, 2], total: 10, requests: requests)

        await model.loadNextPage()?.value
        // Each empty page started the next load, so the in-flight load is the auto-advanced one.
        while let task = model.loadNextPage() { await task.value }
        #expect(requests.value == [0, 1, 2])
        #expect(model.items == items(1...2))
        #expect(model.reachedEnd)
    }

    @Test func automaticAdvanceIsBounded() async {
        let requests = Locked<[Int]>([])
        let malformed = Array(repeating: [TestItem](), count: 10)
        let model = makeLossyModel(
            pages: malformed, rawCounts: Array(repeating: 4, count: 10), total: 40, requests: requests)

        await model.loadNextPage()?.value
        while model.isLoading, let task = model.loadNextPage() { await task.value }
        // Three empty pages in a row stop the automatic loads; a scroll or call continues.
        #expect(requests.value == [0, 1, 2])
        #expect(!model.reachedEnd)
        #expect(!model.isLoading)
        await model.loadNextPage()?.value
        #expect(requests.value.count == 4)
    }
}
