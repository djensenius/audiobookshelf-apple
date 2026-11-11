import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

@MainActor
@Suite struct SearchModelTests {
    let clock = ManualClock()
    let gate = GatedCalls<SearchRequest, LibrarySearchResults>()

    func makeModel(recentSearches: [String] = [], limit: Int? = nil) -> SearchModel {
        let gate = gate
        return SearchModel(
            service: FakeSearchService { try await gate.call($0) }, libraryID: "lib", recentSearches: recentSearches,
            limit: limit, clock: clock)
    }

    @Test func typingSearchesAfter300Milliseconds() async throws {
        let model = makeModel(limit: 5)
        var calls = gate.calls.makeAsyncIterator()
        var sleeps = clock.sleeps.makeAsyncIterator()

        model.setQuery("  one ")
        #expect(await sleeps.next() == .milliseconds(300))
        clock.advance(by: .milliseconds(299))
        #expect(clock.sleeperCount == 1)
        #expect(!model.isSearching)

        clock.advance(by: .milliseconds(1))
        let call = try #require(await calls.next())
        #expect(call.request == SearchRequest(libraryID: "lib", query: "one", limit: 5))
        #expect(model.isSearching)
        call.reply.resume(returning: try bookResults("li1"))
        await model.searchTask?.value

        #expect(!model.isSearching)
        #expect(model.searchedQuery == "one")
        #expect(model.results.rows(.books).map(\.route) == [.item(id: "li1")])
        #expect(model.query == "  one ")
        // Typing doesn't remember the query; only submitting does.
        #expect(model.recentSearches.isEmpty)
    }

    @Test func typingAgainRestartsTheDebounce() async throws {
        let model = makeModel()
        var calls = gate.calls.makeAsyncIterator()
        var sleeps = clock.sleeps.makeAsyncIterator()

        model.setQuery("o")
        #expect(await sleeps.next() == .milliseconds(300))
        let first = try #require(model.searchTask)
        clock.advance(by: .milliseconds(200))
        model.setQuery("on")
        await first.value
        #expect(await sleeps.next() == .milliseconds(300))
        // The first deadline passes without a request: only the restarted debounce is waiting.
        clock.advance(by: .milliseconds(100))
        #expect(clock.sleeperCount == 1)
        #expect(!model.isSearching)

        clock.advance(by: .milliseconds(200))
        let call = try #require(await calls.next())
        #expect(call.request.query == "on")
        call.reply.resume(returning: try bookResults("li1"))
        await model.searchTask?.value
        #expect(model.searchedQuery == "on")
    }

    @Test func submitSearchesAtOnceAndCancelsTheDebounce() async throws {
        let model = makeModel()
        var calls = gate.calls.makeAsyncIterator()
        var sleeps = clock.sleeps.makeAsyncIterator()

        model.setQuery("one")
        _ = await sleeps.next()
        model.submit()
        #expect(clock.sleeperCount == 0)

        let call = try #require(await calls.next())
        #expect(call.request.query == "one")
        call.reply.resume(returning: try bookResults("li1"))
        await model.searchTask?.value
        #expect(model.searchedQuery == "one")
        #expect(clock.sleeperCount == 0)
    }

    @Test func settingTheSameQueryKeepsTheRunningSearch() async throws {
        let model = makeModel()
        var calls = gate.calls.makeAsyncIterator()

        model.setQuery("one")
        model.submit()
        let running = try #require(model.searchTask)
        model.setQuery("one")
        #expect(model.searchTask == running)
        #expect(!running.isCancelled)
        #expect(clock.sleeperCount == 0)

        try #require(await calls.next()).reply.resume(returning: try bookResults("li1"))
        await running.value
        #expect(model.searchedQuery == "one")
    }

    @Test func aDiscardedModelCancelsItsSearch() async throws {
        let requests = Locked(0)
        var sleeps = clock.sleeps.makeAsyncIterator()
        var model: SearchModel? = SearchModel(
            service: FakeSearchService { _ in
                requests.value += 1
                return LibrarySearchResults()
            }, libraryID: "lib", clock: clock)

        model?.setQuery("x")
        _ = await sleeps.next()
        let task = try #require(model?.searchTask)
        model = nil
        #expect(task.isCancelled)
        #expect(clock.sleeperCount == 0)

        clock.advance(by: .milliseconds(300))
        await task.value
        #expect(requests.value == 0)
    }

    @Test func aStaleResponseIsDropped() async throws {
        let model = makeModel()
        var calls = gate.calls.makeAsyncIterator()

        model.setQuery("old")
        model.submit()
        let stale = try #require(model.searchTask)
        let staleCall = try #require(await calls.next())
        model.setQuery("new")
        model.submit()
        #expect(stale.isCancelled)
        let freshCall = try #require(await calls.next())

        // The old request answers first, then the new one; neither order may show old results.
        staleCall.reply.resume(returning: try bookResults("old"))
        await stale.value
        #expect(model.results.isEmpty)
        #expect(model.isSearching)

        freshCall.reply.resume(returning: try bookResults("new"))
        await model.searchTask?.value
        #expect(model.results.rows(.books).map(\.route) == [.item(id: "new")])
        #expect(model.searchedQuery == "new")
        #expect(!model.isSearching)
    }

    @Test func aLateStaleResponseDoesNotReplaceNewerResults() async throws {
        let model = makeModel()
        var calls = gate.calls.makeAsyncIterator()

        model.setQuery("old")
        model.submit()
        let stale = try #require(model.searchTask)
        let staleCall = try #require(await calls.next())
        model.setQuery("new")
        model.submit()
        let freshCall = try #require(await calls.next())

        freshCall.reply.resume(returning: try bookResults("new"))
        await model.searchTask?.value
        staleCall.reply.resume(throwing: TestError.offline)
        await stale.value

        #expect(model.results.rows(.books).map(\.route) == [.item(id: "new")])
        #expect(model.error == nil)
    }

    @Test func aBlankQueryClearsWithoutARequest() async throws {
        let model = makeModel()
        var calls = gate.calls.makeAsyncIterator()

        model.setQuery("one")
        model.submit()
        let call = try #require(await calls.next())
        call.reply.resume(returning: try bookResults("li1"))
        await model.searchTask?.value
        #expect(!model.results.isEmpty)

        // A request in flight when the query is cleared is dropped too.
        model.setQuery("two")
        model.submit()
        let inFlight = try #require(model.searchTask)
        let lateCall = try #require(await calls.next())

        model.setQuery(" \n ")
        #expect(model.searchTask == nil)
        #expect(clock.sleeperCount == 0)
        #expect(model.results.isEmpty)
        #expect(model.searchedQuery == nil)
        #expect(!model.isSearching)

        lateCall.reply.resume(returning: try bookResults("li2"))
        await inFlight.value
        #expect(model.results.isEmpty)

        model.submit()
        #expect(model.searchTask == nil)
        #expect(model.recentSearches == ["two", "one"])
    }

    @Test func aFailureKeepsThePreviousResults() async throws {
        let model = makeModel()
        var calls = gate.calls.makeAsyncIterator()

        model.setQuery("one")
        model.submit()
        try #require(await calls.next()).reply.resume(returning: try bookResults("li1"))
        await model.searchTask?.value

        model.setQuery("two")
        model.submit()
        try #require(await calls.next()).reply.resume(throwing: TestError.offline)
        await model.searchTask?.value

        #expect(model.error as? TestError == .offline)
        #expect(model.results.rows(.books).map(\.route) == [.item(id: "li1")])
        #expect(model.searchedQuery == "one")
        #expect(!model.isSearching)

        model.submit()
        try #require(await calls.next()).reply.resume(returning: try bookResults("li2"))
        await model.searchTask?.value
        #expect(model.error == nil)
        #expect(model.searchedQuery == "two")
    }

    @Test func recentSearchesAreDeduplicatedCappedAndPersisted() async throws {
        let saved = Locked<[[String]]>([])
        let model = SearchModel(
            service: FakeSearchService { _ in LibrarySearchResults() }, libraryID: "lib",
            recentSearches: ["Dune", " ", "dune", "Emma"], clock: clock
        ) { saved.value.append($0) }
        #expect(model.recentSearches == ["Dune", "Emma"])

        model.setQuery(" EMMA ")
        model.submit()
        await model.searchTask?.value
        #expect(model.recentSearches == ["EMMA", "Dune"])
        #expect(saved.value == [["EMMA", "Dune"]])

        // Submitting the latest search again changes nothing.
        model.submit()
        await model.searchTask?.value
        #expect(saved.value.count == 1)

        for index in 1...10 {
            model.setQuery("q\(index)")
            model.submit()
        }
        await model.searchTask?.value
        #expect(model.recentSearches == (1...10).reversed().map { "q\($0)" })

        model.clearRecentSearches()
        #expect(model.recentSearches.isEmpty)
        #expect(saved.value.last == [])
    }

    @Test func withLoadRecentsTheSavedListIsTheOnlyCopy() async throws {
        let stored = Locked<[String]>(["Dune", "dune", " "])
        func makeSharedModel() -> SearchModel {
            SearchModel(
                service: FakeSearchService { _ in LibrarySearchResults() }, libraryID: "lib", clock: clock,
                persistRecents: { stored.value = $0 }, loadRecents: { stored.value })
        }
        let first = makeSharedModel()
        let second = makeSharedModel()
        #expect(first.recentSearches == ["Dune"])

        first.clearRecentSearches()
        #expect(second.recentSearches.isEmpty)

        second.setQuery("Emma")
        second.submit()
        await second.searchTask?.value
        #expect(stored.value == ["Emma"])
        #expect(first.recentSearches == ["Emma"])
    }

    @Test func savedRecentSearchesAreCapped() {
        let model = makeModel(recentSearches: (1...12).map { "q\($0)" })
        #expect(model.recentSearches == (1...10).map { "q\($0)" })
    }
}
