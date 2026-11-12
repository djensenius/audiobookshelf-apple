import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

func makeLibraryItem(_ id: String) throws -> LibraryItem {
    let json = #"{"id":"\#(id)","libraryId":"lib","mediaType":"book"}"#
    return try JSONDecoder().decode(LibraryItem.self, from: Data(json.utf8))
}

/// A display value that isn't `Decodable`.
struct Slim: Identifiable, Sendable, Equatable {
    let id: String
}

private struct ItemsRequest: Sendable {
    let libraryID: String
    let query: LibraryQuery
}

@MainActor
private struct Harness {
    let gate = GatedCalls<ItemsRequest, PagedResults<LibraryItem>>()
    let saved = Locked<[String: LibraryViewPreferences]>([:])
    var model: LibraryBrowseModel<Slim>

    init(
        libraryID: String = "books", mediaType: MediaType = .book, stored: LibraryViewPreferences? = nil,
        pinnedFilter: LibraryViewPreferences.Filter? = nil, pageSize: Int = 2
    ) {
        let gate = gate
        let saved = saved
        let service = FakeLibraryService(itemsHandler: { libraryID, query in
            try await gate.call(ItemsRequest(libraryID: libraryID, query: query))
        })
        model = LibraryBrowseModel(
            client: service, libraryID: libraryID, mediaType: mediaType, stored: stored, pinnedFilter: pinnedFilter,
            pageSize: pageSize, persist: { id, _, preferences in saved.value[id] = preferences },
            map: { Slim(id: $0.id) })
    }
}

private func page(_ ids: [String], total: Int, page: Int = 0) throws -> PagedResults<LibraryItem> {
    PagedResults(results: try ids.map(makeLibraryItem), total: total, limit: 2, page: page)
}

@MainActor
@Suite struct LibraryBrowseModelTests {
    @Test func loadsSlimValuesWithTheQueryFromThePreferences() async throws {
        let harness = Harness(
            stored: LibraryViewPreferences(sort: .title, descending: false, filter: .init(group: .genres, value: "G")))
        let load = harness.model.load()
        var calls = harness.gate.calls.makeAsyncIterator()
        let call = try #require(await calls.next())
        #expect(call.request.libraryID == "books")
        #expect(call.request.query.sort == "media.metadata.title")
        #expect(call.request.query.filter == LibraryFilter.genres("G"))
        #expect(call.request.query.page == 0 && call.request.query.limit == 2)
        call.reply.resume(returning: try page(["a", "b"], total: 3))
        await load?.value

        #expect(harness.model.items == [Slim(id: "a"), Slim(id: "b")])
        #expect(harness.model.total == 3)
        #expect(!harness.model.isLoading)
        #expect(!harness.model.reachedEnd)

        let next = harness.model.load()
        let second = try #require(await calls.next())
        #expect(second.request.query.page == 1)
        second.reply.resume(returning: try page(["c"], total: 3, page: 1))
        await next?.value
        #expect(harness.model.items.map(\.id) == ["a", "b", "c"])
        #expect(harness.model.reachedEnd)
    }

    @Test func aPageThatArrivesAfterAPreferenceChangeIsDropped() async throws {
        let harness = Harness()
        let first = harness.model.load()
        var calls = harness.gate.calls.makeAsyncIterator()
        let stale = try #require(await calls.next())

        let second = harness.model.update { $0.selectSort(.title) }
        let fresh = try #require(await calls.next())
        #expect(fresh.request.query.sort == "media.metadata.title")

        fresh.reply.resume(returning: try page(["new"], total: 1))
        await second?.value
        stale.reply.resume(returning: try page(["old1", "old2"], total: 2))
        await first?.value

        #expect(harness.model.items.map(\.id) == ["new"])
        #expect(harness.model.total == 1)
    }

    @Test func aPageThatArrivesAfterALibrarySwitchIsDropped() async throws {
        let harness = Harness(libraryID: "books")
        let first = harness.model.load()
        var calls = harness.gate.calls.makeAsyncIterator()
        let stale = try #require(await calls.next())

        let second = harness.model.switchLibrary(id: "pods", mediaType: .podcast)
        let fresh = try #require(await calls.next())
        #expect(fresh.request.libraryID == "pods")

        stale.reply.resume(returning: try page(["book"], total: 1))
        await first?.value
        #expect(harness.model.items.isEmpty)
        #expect(harness.model.libraryID == "pods")

        fresh.reply.resume(returning: try page(["episode"], total: 1))
        await second?.value
        #expect(harness.model.items.map(\.id) == ["episode"])
    }

    @Test func updatingSavesTheRepairedChangeAndOpeningDoesNot() async throws {
        let harness = Harness(
            libraryID: "pods", mediaType: .podcast, stored: LibraryViewPreferences(sort: .duration, descending: false))
        #expect(harness.model.preferences.sort == .episodeCount)
        #expect(harness.saved.value.isEmpty)

        _ = harness.model.load()
        var calls = harness.gate.calls.makeAsyncIterator()
        _ = try #require(await calls.next())
        #expect(harness.saved.value.isEmpty)

        _ = harness.model.update { $0.viewMode = .list }
        #expect(harness.saved.value["pods"]?.viewMode == .list)
        #expect(harness.saved.value["pods"]?.sort == .episodeCount)
    }

    @Test func switchingLibrariesRepairsWithoutSavingAndKeepsTheStoredChoice() async throws {
        let stored = LibraryViewPreferences(sort: .authorFirstLast, filter: .init(group: .narrators, value: "N"))
        let harness = Harness(stored: stored)
        _ = harness.model.switchLibrary(id: "pods", mediaType: .podcast, stored: stored)
        var calls = harness.gate.calls.makeAsyncIterator()
        let call = try #require(await calls.next())
        #expect(call.request.query.sort == "media.metadata.author")
        #expect(call.request.query.filter == nil)
        #expect(harness.saved.value.isEmpty)

        _ = harness.model.switchLibrary(id: "books", mediaType: .book, stored: stored)
        _ = try #require(await calls.next())
        #expect(harness.model.preferences == stored)
    }

    @Test func aPinnedFilterIsQueriedButAnUpdateSavesTheStoredFilter() async throws {
        let stored = LibraryViewPreferences(filter: .init(group: .genres, value: "G"))
        let pinned = LibraryViewPreferences.Filter(group: .narrators, value: "Jim Dale")
        let harness = Harness(stored: stored, pinnedFilter: pinned)
        #expect(harness.model.preferences.filter == pinned)
        #expect(!harness.model.isFilterUnsupported)

        _ = harness.model.load()
        var calls = harness.gate.calls.makeAsyncIterator()
        let first = try #require(await calls.next())
        #expect(first.request.query.filter == LibraryFilter.narrators("Jim Dale"))
        // The name goes out Base64-encoded, like the legacy `$encode`.
        #expect(first.request.query.queryItems.first == URLQueryItem(name: "filter", value: "narrators.SmltIERhbGU%3D"))
        first.reply.resume(returning: try page([], total: 0))
        #expect(harness.saved.value.isEmpty)

        _ = harness.model.update {
            $0.selectSort(.title)
            $0.viewMode = .list
            $0.collapseSeries = true
            $0.filter = nil
        }
        let second = try #require(await calls.next())
        #expect(second.request.query.sort == "media.metadata.title")
        #expect(second.request.query.filter == LibraryFilter.narrators("Jim Dale"))
        second.reply.resume(returning: try page([], total: 0))
        #expect(harness.model.preferences.filter == pinned)
        #expect(
            harness.saved.value["books"]
                == LibraryViewPreferences(
                    sort: .title, descending: false, filter: stored.filter, viewMode: .list, collapseSeries: true))
    }

    @Test func anUnsupportedPinnedFilterRequestsNothing() async throws {
        let requests = Locked<[LibraryQuery]>([])
        let service = FakeLibraryService(itemsHandler: { _, query in
            requests.value.append(query)
            return try page(["item"], total: 1)
        })
        let pinned = LibraryViewPreferences.Filter(group: .narrators, value: "N")
        let model = LibraryBrowseModel(
            client: service, libraryID: "pods", mediaType: .podcast, pinnedFilter: pinned, map: { Slim(id: $0.id) })
        #expect(model.isFilterUnsupported)
        #expect(model.preferences.filter == pinned)

        await model.load()?.value
        await model.update { $0.selectSort(.title) }?.value
        await model.list.refresh()?.value
        #expect(requests.value.isEmpty)
        #expect(model.items.isEmpty && model.total == 0 && model.reachedEnd)

        // Book libraries offer narrators; back in a podcast library the list empties again.
        await model.switchLibrary(id: "books", mediaType: .book)?.value
        #expect(!model.isFilterUnsupported)
        #expect(requests.value.map(\.filter) == [LibraryFilter.narrators("N")])
        #expect(model.items.map(\.id) == ["item"])
        await model.switchLibrary(id: "pods", mediaType: .podcast)?.value
        #expect(requests.value.count == 1)
        #expect(model.items.isEmpty && model.reachedEnd)
    }

    @Test(arguments: [
        LibraryViewPreferences.Filter(group: .narrators),
        LibraryViewPreferences.Filter(group: .progress, value: "bogus"),
    ])
    func aPinnedFilterWithoutAUsableValueRequestsNothing(pinned: LibraryViewPreferences.Filter) async throws {
        let requests = Locked(0)
        let service = FakeLibraryService(itemsHandler: { _, _ in
            requests.value += 1
            return try page(["item"], total: 1)
        })
        let model = LibraryBrowseModel(
            client: service, libraryID: "books", mediaType: .book, pinnedFilter: pinned, map: { Slim(id: $0.id) })
        #expect(model.isFilterUnsupported)

        await model.load()?.value
        await model.list.refresh()?.value
        #expect(requests.value == 0)
        #expect(model.items.isEmpty && model.reachedEnd)
    }

    @Test func settingTheSameQueryAgainDoesNotReload() async throws {
        let harness = Harness()
        let load = harness.model.load()
        var calls = harness.gate.calls.makeAsyncIterator()
        let call = try #require(await calls.next())
        call.reply.resume(returning: try page([], total: 0))
        await load?.value
        #expect(harness.model.update { _ in } == nil)
    }

    @Test func aFailedPageIsReportedAndRetriedByLoadingAgain() async throws {
        let harness = Harness()
        let load = harness.model.load()
        var calls = harness.gate.calls.makeAsyncIterator()
        let failing = try #require(await calls.next())
        failing.reply.resume(throwing: TestError.offline)
        await load?.value
        #expect(harness.model.error != nil)
        #expect(harness.model.items.isEmpty)

        let retry = harness.model.load()
        let again = try #require(await calls.next())
        #expect(again.request.query.page == 0)
        again.reply.resume(returning: try page(["a"], total: 1))
        await retry?.value
        #expect(harness.model.error == nil)
        #expect(harness.model.items.map(\.id) == ["a"])
    }

    @Test func theListModelNoLongerNeedsDecodableItems() async {
        let model = ItemListModel<String, Slim>(query: "q", pageSize: 2) { _, page, limit in
            PagedResults(results: [Slim(id: "p\(page)")], total: 1, limit: limit, page: page)
        }
        await model.loadNextPage()?.value
        #expect(model.items == [Slim(id: "p0")])
        #expect(model.reachedEnd)
    }

    @Test func mappingAPageKeepsItsPagingFields() throws {
        let source = PagedResults(results: [1, 2, 3], total: 9, limit: 3, page: 2, rawCount: 5)
        let mapped = source.map { String($0) }
        #expect(mapped.results == ["1", "2", "3"])
        #expect(mapped.rawCount == 5 && mapped.total == 9 && mapped.limit == 3 && mapped.page == 2)
    }
}
