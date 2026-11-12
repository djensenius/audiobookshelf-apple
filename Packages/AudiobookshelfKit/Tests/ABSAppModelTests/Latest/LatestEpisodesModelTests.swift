import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

/// A recorded `recentEpisodes` request.
private struct RecentRequest: Sendable, Equatable {
    let libraryID: String
    let page: Int
    let limit: Int
}

/// A ``LatestEpisodesService`` answering from a closure.
private struct FakeLatestEpisodesService: LatestEpisodesService {
    var handler: @Sendable (RecentRequest) async throws -> RecentEpisodesPage

    func recentEpisodes(libraryID: String, page: Int, limit: Int) async throws -> RecentEpisodesPage {
        try await handler(RecentRequest(libraryID: libraryID, page: page, limit: limit))
    }
}

/// A store client whose `recentEpisodes` waits for the test.
private struct GatedLatestClient: LibraryService, LatestEpisodesService {
    let gate: GatedCalls<RecentRequest, RecentEpisodesPage>

    func libraries() async throws -> [Library] { [] }
    func library(id: String) async throws -> LibraryWithFilterData { throw TestError.unexpected }
    func personalizedShelves(libraryID: String) async throws -> [Shelf] { [] }
    func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> {
        throw TestError.unexpected
    }
    func recentEpisodes(libraryID: String, page: Int, limit: Int) async throws -> RecentEpisodesPage {
        try await gate.call(RecentRequest(libraryID: libraryID, page: page, limit: limit))
    }
}

private enum F {
    /// An episode `id` of the podcast item `item`; `inEpisode` puts the item ID on the episode,
    /// else only on the podcast.
    static func recent(
        _ id: String, item: String? = "pod", inEpisode: Bool = true, duration: Double? = 600,
        coverPath: String? = "/metadata/items/pod/cover.jpg", explicit: Bool = false
    ) -> RecentEpisode {
        let podcast = Podcast(
            id: "podcast-\(item ?? "none")", libraryItemId: inEpisode ? nil : item,
            metadata: PodcastMetadata(title: "Podcast \(item ?? "none")", explicit: explicit), coverPath: coverPath)
        return RecentEpisode(
            episode: PodcastEpisode(
                id: id, libraryItemId: inEpisode ? item : nil, title: "Episode \(id)", duration: duration),
            podcast: podcast, libraryId: "lib")
    }

    static func episodes(_ range: ClosedRange<Int>) -> [RecentEpisode] {
        range.map { recent("e\($0)") }
    }

    static func page(_ episodes: [RecentEpisode], limit: Int, page: Int = 0, rawCount: Int? = nil)
        -> RecentEpisodesPage
    {
        RecentEpisodesPage(episodes: episodes, limit: limit, page: page, rawCount: rawCount)
    }
}

@MainActor
private func makeModel(
    pages: [[RecentEpisode]], pageSize: Int = 3, cache: ProgressCache = ProgressCache(),
    requests: Locked<[RecentRequest]> = Locked([])
) -> LatestEpisodesModel {
    let service = FakeLatestEpisodesService { request in
        requests.value.append(request)
        let episodes = request.page < pages.count ? pages[request.page] : []
        return F.page(episodes, limit: request.limit, page: request.page)
    }
    return LatestEpisodesModel(
        service: service, libraryID: "lib", cache: cache, pageSize: pageSize, prefetchThreshold: 1)
}

@MainActor
@Suite struct LatestEpisodesModelTests {
    // MARK: Paging

    @Test func loadsTheNextPageNearTheEndAndStopsAtAShortPage() async throws {
        let requests = Locked<[RecentRequest]>([])
        let model = makeModel(pages: [F.episodes(1...3), F.episodes(4...5)], requests: requests)
        await model.list.loadNextPage()?.value
        #expect(model.list.items.map(\.episode.id) == ["e1", "e2", "e3"])
        #expect(!model.list.reachedEnd)

        await model.list.loadNextPage()?.value
        #expect(model.list.items.map(\.episode.id) == ["e1", "e2", "e3", "e4", "e5"])
        #expect(model.list.reachedEnd)
        #expect(model.list.loadNextPage() == nil)
        #expect(
            requests.value == [
                RecentRequest(libraryID: "lib", page: 0, limit: 3), RecentRequest(libraryID: "lib", page: 1, limit: 3),
            ])
    }

    @Test func anAppearingRowNearTheEndRequestsTheNextPage() async throws {
        let requests = Locked<[RecentRequest]>([])
        let model = makeModel(pages: [F.episodes(1...3), F.episodes(4...6), []], requests: requests)
        await model.list.loadNextPage()?.value
        model.list.itemAppeared(id: "pod-e1")
        #expect(!model.list.isLoading)
        model.list.itemAppeared(id: "pod-e3")
        #expect(model.list.isLoading)
        await model.list.loadNextPage()?.value
        #expect(requests.value.map(\.page) == [0, 1])
        #expect(model.list.items.count == 6)
    }

    @Test func aFullLastPageEndsWithTheEmptyPageAfterIt() async throws {
        let model = makeModel(pages: [F.episodes(1...3)])
        await model.list.loadNextPage()?.value
        #expect(!model.list.reachedEnd)
        await model.list.loadNextPage()?.value
        #expect(model.list.reachedEnd)
        #expect(model.list.items.count == 3)
    }

    @Test func aSecondLoadWhileOneIsInFlightJoinsIt() async throws {
        let gate = GatedCalls<RecentRequest, RecentEpisodesPage>()
        var calls = gate.calls.makeAsyncIterator()
        let requests = Locked(0)
        let service = FakeLatestEpisodesService { request in
            requests.value += 1
            return try await gate.call(request)
        }
        let model = LatestEpisodesModel(service: service, libraryID: "lib", cache: ProgressCache(), pageSize: 3)
        let first = model.list.loadNextPage()
        let call = try #require(await calls.next())
        // A second load, and a row appearing at the end, while the page is in flight.
        let second = model.list.loadNextPage()
        model.list.itemAppeared(at: 0)
        #expect(first == second)
        call.reply.resume(returning: F.page(F.episodes(1...2), limit: 3))
        await first?.value
        #expect(requests.value == 1)
        #expect(model.list.items.count == 2)
        #expect(model.list.reachedEnd)
    }

    @Test func rowsWithoutAnItemAreDroppedButStillCountTowardsThePage() async throws {
        let requests = Locked<[RecentRequest]>([])
        // Page 0 is full on the wire, though one row has no library item.
        let pages = [[F.recent("e1"), F.recent("orphan", item: nil), F.recent("e3")], [F.recent("e4")]]
        let model = makeModel(pages: pages, requests: requests)
        await model.list.loadNextPage()?.value
        #expect(model.list.items.map(\.episode.id) == ["e1", "e3"])
        #expect(!model.list.reachedEnd)
        await model.list.loadNextPage()?.value
        #expect(model.list.items.map(\.episode.id) == ["e1", "e3", "e4"])
        #expect(model.list.reachedEnd)
    }

    @Test func aLateFirstPageOfThePreviousLibraryIsDropped() async throws {
        let gate = GatedCalls<RecentRequest, RecentEpisodesPage>()
        var calls = gate.calls.makeAsyncIterator()
        let model = LatestEpisodesModel(
            service: FakeLatestEpisodesService { try await gate.call($0) }, libraryID: "lib-a", cache: ProgressCache(),
            pageSize: 3)
        let stale = model.list.loadNextPage()
        let staleCall = try #require(await calls.next())
        #expect(staleCall.request.libraryID == "lib-a")

        let current = model.list.setQuery("lib-b")
        let currentCall = try #require(await calls.next())
        #expect(currentCall.request.libraryID == "lib-b")
        currentCall.reply.resume(returning: F.page([F.recent("b1", item: "pod-b")], limit: 3))
        await current?.value
        staleCall.reply.resume(returning: F.page([F.recent("a1", item: "pod-a")], limit: 3))
        await stale?.value

        #expect(model.list.items.map(\.id) == ["pod-b-b1"])
        #expect(model.list.error == nil)
    }

    @Test func aPageAnsweredAfterAnAccountSwitchIsDropped() async throws {
        let serverA = LibraryConnectionKey(connectionID: UUID(), userID: "user-a")
        let serverB = LibraryConnectionKey(connectionID: UUID(), userID: "user-b")
        try await withLibrarySettings { settings in
            let gate = GatedCalls<RecentRequest, RecentEpisodesPage>()
            var calls = gate.calls.makeAsyncIterator()
            let store = LibraryStore(settings: settings)
            await store.connect(client: GatedLatestClient(gate: gate), connectionKey: serverA)
            let services = try #require(store.makeServices())
            let model = LatestEpisodesModel(
                service: services, libraryID: "lib", cache: store.progress, connectionKey: services.connectionKey)

            let load = model.list.loadNextPage()
            let call = try #require(await calls.next())
            await store.connect(client: FakeLibraryService(), connectionKey: serverB)
            call.reply.resume(returning: F.page(F.episodes(1...2), limit: 50))
            await load?.value

            #expect(model.list.items.isEmpty)
            // Dropped as a cancellation, not shown as the new account's failure.
            #expect(model.list.error == nil)
            #expect(!model.list.isLoading)
        }
    }

    // MARK: States

    @Test func anEmptyLibraryEndsWithNoRowsAndNoError() async throws {
        let model = makeModel(pages: [])
        await model.list.loadNextPage()?.value
        #expect(model.list.items.isEmpty)
        #expect(model.list.reachedEnd)
        #expect(model.list.error == nil)
    }

    @Test func aFailedLoadKeepsTheRowsAndRetryLoadsThePageAgain() async throws {
        let fails = Locked(true)
        let requests = Locked<[RecentRequest]>([])
        let service = FakeLatestEpisodesService { request in
            requests.value.append(request)
            if request.page == 1, fails.value { throw TestError.offline }
            return F.page(request.page == 0 ? F.episodes(1...3) : F.episodes(4...4), limit: 3, page: request.page)
        }
        let model = LatestEpisodesModel(service: service, libraryID: "lib", cache: ProgressCache(), pageSize: 3)
        await model.list.loadNextPage()?.value
        await model.list.loadNextPage()?.value
        #expect(model.list.error is TestError)
        #expect(model.list.items.count == 3)
        #expect(!model.list.reachedEnd)

        fails.value = false
        await model.list.loadNextPage()?.value
        #expect(model.list.error == nil)
        #expect(model.list.items.count == 4)
        #expect(requests.value.map(\.page) == [0, 1, 1])
    }

    @Test func aFailedFirstLoadHasNoRows() async throws {
        let service = FakeLatestEpisodesService { _ in throw TestError.offline }
        let model = LatestEpisodesModel(service: service, libraryID: "lib", cache: ProgressCache())
        await model.list.loadNextPage()?.value
        #expect(model.list.items.isEmpty)
        #expect(model.list.error is TestError)
        #expect(!model.list.reachedEnd)
    }

    // MARK: Rows

    @Test func mapsTheEpisodeAndItsPodcast() throws {
        let row = try #require(
            LatestEpisode(F.recent("e1", item: "pod", coverPath: "https://cdn.example.com/c.jpg", explicit: true)))
        #expect(row.id == "pod-e1")
        #expect(row.itemID == "pod")
        #expect(row.summary.episodeID == "e1")
        #expect(row.summary.kind == .episode)
        #expect(row.summary.title == "Episode e1")
        #expect(row.summary.subtitle == "Podcast pod")
        #expect(row.summary.duration == 600)
        #expect(row.summary.isExplicit)
        #expect(
            row.summary.cover == CoverRef(entityID: "pod", externalURL: URL(string: "https://cdn.example.com/c.jpg")))
        #expect(row.summary.progressKey == MediaProgress.key(libraryItemID: "pod", episodeID: "e1"))
    }

    @Test func takesTheItemFromThePodcastAndKeepsLocalCoversOnTheServer() throws {
        let row = try #require(LatestEpisode(F.recent("e1", item: "pod", inEpisode: false)))
        #expect(row.itemID == "pod")
        #expect(row.summary.cover == CoverRef(entityID: "pod"))
        let noCover = try #require(LatestEpisode(F.recent("e2", coverPath: nil, explicit: false)))
        #expect(noCover.summary.cover == nil)
        #expect(!noCover.summary.isExplicit)
        #expect(LatestEpisode(F.recent("e3", item: nil)) == nil)
        #expect(LatestEpisode(F.recent("e4", duration: 0))?.summary.duration == nil)
    }

    @Test func rowsFollowTheirEpisodesProgress() async throws {
        let cache = ProgressCache()
        let model = makeModel(pages: [[F.recent("e1"), F.recent("e2"), F.recent("e3", duration: nil)]], cache: cache)
        await model.list.loadNextPage()?.value
        let rows = model.list.items
        try #require(rows.count == 3)
        #expect(model.status(for: rows[0]) == .notStarted(duration: 600))
        #expect(model.itemProgress(for: rows[0]) == nil)

        cache.apply(
            MediaProgress(
                id: "p1", libraryItemId: "pod", episodeId: "e1", duration: 600, progress: 0.25, currentTime: 150,
                lastUpdate: 1))
        cache.apply(
            MediaProgress(id: "p2", libraryItemId: "pod", episodeId: "e2", progress: 1, isFinished: true, lastUpdate: 1)
        )
        // Progress on the podcast item itself isn't an episode's.
        cache.apply(MediaProgress(id: "p3", libraryItemId: "pod", progress: 0.5, currentTime: 10, lastUpdate: 1))

        #expect(model.status(for: rows[0]) == .inProgress(remaining: 450))
        #expect(model.itemProgress(for: rows[0])?.fraction == 0.25)
        #expect(model.itemProgress(for: rows[0])?.isInProgress == true)
        #expect(model.status(for: rows[1]) == .finished)
        #expect(model.itemProgress(for: rows[1])?.isFinished == true)
        #expect(model.status(for: rows[2]) == .notStarted(duration: nil))
        #expect(model.itemProgress(for: rows[2]) == nil)
    }
}
