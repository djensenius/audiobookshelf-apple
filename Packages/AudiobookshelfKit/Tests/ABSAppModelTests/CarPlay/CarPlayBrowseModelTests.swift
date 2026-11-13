import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

let browseAccount = SessionIdentity(
    connectionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1") ?? UUID(), userID: "user-1")
let browseLabels = CarPlayLabels(
    continueListening: "Continue", libraries: "Libraries", books: "Books", podcasts: "Podcasts", series: "Series",
    authors: "Authors", latest: "Latest", more: "More")

/// A store client serving the browse tabs from in-memory libraries. Paged endpoints slice their
/// lists by the request's page and limit, and every request is recorded.
struct FakeCarPlayBrowseService: CarPlayBrowseService {
    let libraryList = Locked<[Library]>([])
    /// Books (or podcasts) by library.
    let books = Locked<[String: [LibraryItem]]>([:])
    let series = Locked<[String: [Series]]>([:])
    let authors = Locked<[String: [Author]]>([:])
    /// Podcast items by ID, for their episodes.
    let podcasts = Locked<[String: LibraryItem]>([:])
    let recent = Locked<[String: [RecentEpisode]]>([:])
    let requests = Locked<[String]>([])
    let failsLibraries = Locked(false)
    let failsBooks = Locked(false)
    /// While set, a books request waits for ``releaseBooks()``.
    let holdsBooks = Locked(false)
    let heldBooks = Locked<[CheckedContinuation<Void, Never>]>([])

    func releaseBooks() {
        let held = heldBooks.value
        heldBooks.value = []
        held.forEach { $0.resume() }
    }

    private func slice<Element: Sendable>(_ all: [Element], page: Int?, limit: Int?) -> PagedResults<Element> {
        let page = page ?? 0
        let limit = limit ?? 0
        guard limit > 0 else { return PagedResults(results: all, total: all.count, limit: limit, page: page) }
        let start = min(page * limit, all.count)
        let results = Array(all[start..<min(start + limit, all.count)])
        return PagedResults(results: results, total: all.count, limit: limit, page: page)
    }

    func libraries() async throws -> [Library] {
        requests.value.append("libraries")
        if failsLibraries.value { throw TestError.offline }
        return libraryList.value
    }
    func library(id: String) async throws -> LibraryWithFilterData { throw TestError.unexpected }
    func personalizedShelves(libraryID: String) async throws -> [Shelf] { [] }
    func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> {
        try await filteredBooksPage(libraryID: libraryID, query: query)
    }
    func item(id: String) async throws -> LibraryItem {
        requests.value.append("item \(id)")
        guard let item = podcasts.value[id] else { throw TestError.unexpected }
        return item
    }
    func seriesPage(libraryID: String, query: LibraryQuery) async throws -> PagedResults<Series> {
        requests.value.append("series \(libraryID) \(query.page ?? 0)")
        return slice(series.value[libraryID] ?? [], page: query.page, limit: query.limit)
    }
    func authorList(libraryID: String) async throws -> [Author] {
        requests.value.append("authors \(libraryID)")
        return authors.value[libraryID] ?? []
    }
    func seriesDetail(id: String) async throws -> SeriesDetailResponse { throw TestError.unexpected }
    func authorDetail(id: String) async throws -> AuthorDetailResponse { throw TestError.unexpected }
    func filteredBooksPage(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> {
        requests.value.append("books \(libraryID) \(query.filter?.queryValue ?? "-") \(query.page ?? 0)")
        if holdsBooks.value { await withCheckedContinuation { heldBooks.value.append($0) } }
        if failsBooks.value { throw TestError.offline }
        var all = books.value[libraryID] ?? []
        if let filter = query.filter, filter.group == "series" {
            all = all.filter { $0.series?.id == filter.value }
        }
        return slice(all, page: query.page, limit: query.limit)
    }
    func recentEpisodes(libraryID: String, page: Int, limit: Int) async throws -> RecentEpisodesPage {
        requests.value.append("recent \(libraryID) \(page)")
        let all = recent.value[libraryID] ?? []
        let start = min(page * limit, all.count)
        return RecentEpisodesPage(episodes: Array(all[start..<min(start + limit, all.count)]), limit: limit, page: page)
    }
}

enum BrowseFixtures {
    static func books(_ count: Int, in libraryID: String = "books", seriesID: String? = nil) -> [LibraryItem] {
        (0..<count).map { SeriesAuthorsFixtures.book("\(libraryID)-\($0)", seriesID: seriesID) }
    }

    static func recent(_ id: String, podcast: String = "pod") -> RecentEpisode {
        RecentEpisode(
            episode: PodcastEpisode(id: id, libraryItemId: podcast, title: "Episode \(id)", duration: 600),
            podcast: Podcast(id: "podcast-\(podcast)", metadata: PodcastMetadata(title: "Podcast \(podcast)")),
            libraryId: "pods")
    }

    static func podcast(_ id: String, episodes: [(String, Int)]) -> LibraryItem {
        LibraryItem(
            id: id, libraryId: "pods", mediaType: .podcast,
            media: .podcast(
                Podcast(
                    id: "podcast-\(id)", metadata: PodcastMetadata(title: "Podcast \(id)"),
                    episodes: episodes.map { PodcastEpisode(id: $0.0, title: "Episode \($0.0)", publishedAt: $0.1) })))
    }
}

/// A store serving `identity`'s account through `service`, and its browse model.
@MainActor
func makeBrowse(
    _ service: FakeCarPlayBrowseService, settings: AppSettings, identity: SessionIdentity = browseAccount,
    limits: CarPlayLimits = CarPlayLimits(), pageSize: Int = 10
) async -> (LibraryStore, CarPlayBrowseModel) {
    let store = LibraryStore(settings: settings)
    await store.connect(
        client: service,
        connectionKey: LibraryConnectionKey(connectionID: identity.connectionID, userID: identity.userID))
    let model = CarPlayBrowseModel(
        store: store, identity: identity, service: service, limits: limits, labels: browseLabels,
        pageSize: pageSize)
    return (store, model)
}

private func ids(_ list: CarPlayList) -> [String] { list.rows.map(\.id) }

@MainActor
@Suite struct CarPlayBrowseModelTests {
    @Test func aLongListPagesWithMoreAndLoadsTheNextPagesItNeeds() async throws {
        try await withLibrarySettings { settings in
            let service = FakeCarPlayBrowseService()
            service.libraryList.value = [makeLibrary("books")]
            service.books.value = ["books": BrowseFixtures.books(23)]
            let (_, model) = await makeBrowse(service, settings: settings, limits: CarPlayLimits(maximumItemCount: 5))
            let books = CarPlayDestination.items(libraryID: "books")

            #expect(model.status(books) == .loading)
            await model.load(books)
            #expect(model.status(books) == .loaded)
            let first = model.list(books)
            #expect(ids(first) == ["books-0", "books-1", "books-2", "books-3", "more-4"])
            #expect(first.rows.last?.action == .more(books, offset: 4))
            #expect(service.requests.value.filter { $0.hasPrefix("books") } == ["books books - 0"])

            // Rows 8 to 12 need a second page of 10.
            await model.load(books, offset: 8)
            #expect(ids(model.list(books, offset: 8)) == ["books-8", "books-9", "books-10", "books-11", "more-12"])
            #expect(service.requests.value.filter { $0.hasPrefix("books") } == ["books books - 0", "books books - 1"])

            // The last page has no "More…".
            await model.load(books, offset: 20)
            #expect(ids(model.list(books, offset: 20)) == ["books-20", "books-21", "books-22"])
            #expect(service.requests.value.filter { $0.hasPrefix("books") }.count == 3)
        }
    }

    @Test func everyListOfTheTreeStaysWithinTheDepthLimit() async throws {
        try await withLibrarySettings { settings in
            let service = FakeCarPlayBrowseService()
            service.libraryList.value = [makeLibrary("books"), makeLibrary("pods", mediaType: .podcast)]
            service.books.value = [
                "books": BrowseFixtures.books(2, seriesID: "s1"),
                "pods": [BrowseFixtures.podcast("pod", episodes: [("e1", 1)])],
            ]
            service.series.value = ["books": [Series(id: "s1", name: "Series s1")]]
            service.authors.value = ["books": [Author(id: "a1", name: "Author a1")]]
            service.podcasts.value = ["pod": BrowseFixtures.podcast("pod", episodes: [("e1", 1)])]
            for depth in 1...5 {
                let (_, model) = await makeBrowse(
                    service, settings: settings, limits: CarPlayLimits(maximumDepth: depth))
                // Walk every row that opens a list, as a driver tapping through the tree would.
                var stack: [CarPlayDestination] = [.libraries]
                var deepest = 0
                while let destination = stack.popLast() {
                    await model.load(destination)
                    let list = model.list(destination)
                    deepest = max(deepest, destination.depth)
                    #expect(destination.depth <= depth)
                    for row in list.rows {
                        guard case .open(let next) = row.action else { continue }
                        let opened = try #require(model.open(row))
                        #expect(opened == next && next.depth == destination.depth + 1)
                        stack.append(opened)
                    }
                }
                // Every level down to the fourth list is reachable once the limit allows it.
                #expect(deepest == min(depth, 4))
            }
        }
    }

    @Test func aRowPastTheDepthLimitOpensNothing() async throws {
        try await withLibrarySettings { settings in
            let service = FakeCarPlayBrowseService()
            service.libraryList.value = [makeLibrary("books")]
            let (_, model) = await makeBrowse(service, settings: settings, limits: CarPlayLimits(maximumDepth: 3))
            let tooDeep = CarPlayRow(
                id: "s1", text: "Series", action: .open(.seriesBooks(libraryID: "books", seriesID: "s1")))
            #expect(model.open(tooDeep) == nil)
            let allowed = CarPlayRow(id: "series", text: "Series", action: .open(.series(libraryID: "books")))
            #expect(model.open(allowed) == .series(libraryID: "books"))
        }
    }

    @Test func openingALibrarySwitchesCarPlaysLibraryAndTheLatestTabFollowsIt() async throws {
        try await withLibrarySettings { settings in
            let service = FakeCarPlayBrowseService()
            service.libraryList.value = [
                makeLibrary("books"), makeLibrary("pods", mediaType: .podcast),
                makeLibrary("talk", mediaType: .podcast),
            ]
            service.recent.value = [
                "pods": [BrowseFixtures.recent("p1")], "talk": [BrowseFixtures.recent("t1", podcast: "show")],
            ]
            let (store, model) = await makeBrowse(service, settings: settings)
            // CarPlay starts in the first library, a book library: Latest shows the first podcasts.
            #expect(store.initialLibraryID == "books")
            #expect(model.latestLibraryID == "pods")

            let libraries = model.list(.libraries)
            let talk = try #require(libraries.rows.first { $0.id == "talk" })
            #expect(model.open(talk) == .library(id: "talk", mediaType: .podcast))
            #expect(store.lastLibraryID == "talk" && store.initialLibraryID == "talk")
            #expect(model.latestLibraryID == "talk")
            let latest = CarPlayDestination.latestEpisodes(libraryID: "talk")
            await model.load(latest)
            #expect(model.list(latest).rows.map(\.action) == [.play(itemID: "show", episodeID: "t1")])
            #expect(model.list(latest).title == "Latest")
        }
    }

    @Test func aLibraryRemovedOnTheServerEmptiesItsListsOnRefresh() async throws {
        try await withLibrarySettings { settings in
            let service = FakeCarPlayBrowseService()
            service.libraryList.value = [makeLibrary("books"), makeLibrary("old")]
            service.books.value = ["books": BrowseFixtures.books(2), "old": BrowseFixtures.books(2, in: "old")]
            let (_, model) = await makeBrowse(service, settings: settings)
            let old = CarPlayDestination.items(libraryID: "old")
            await model.load(old)
            #expect(ids(model.list(old)) == ["old-0", "old-1"])

            service.libraryList.value = [makeLibrary("books")]
            await model.refresh(.libraries)
            #expect(ids(model.list(.libraries)) == ["books"])
            #expect(model.list(old).rows.isEmpty)
            #expect(model.list(.library(id: "old", mediaType: .book)).rows.isEmpty)

            // Back on the server, the library's list loads afresh rather than from its old model.
            service.libraryList.value = [makeLibrary("books"), makeLibrary("old")]
            service.books.value["old"] = BrowseFixtures.books(1, in: "old")
            await model.refresh(.libraries)
            #expect(model.status(old) == .loading)
            await model.load(old)
            #expect(ids(model.list(old)) == ["old-0"])
        }
    }

    @Test func refreshReloadsAListFromItsFirstPageAndKeepsItsPage() async throws {
        try await withLibrarySettings { settings in
            let service = FakeCarPlayBrowseService()
            service.libraryList.value = [makeLibrary("books")]
            service.books.value = ["books": BrowseFixtures.books(30)]
            let (_, model) = await makeBrowse(service, settings: settings, limits: CarPlayLimits(maximumItemCount: 5))
            let books = CarPlayDestination.items(libraryID: "books")
            await model.load(books, offset: 12)
            service.books.value["books"] = Array(BrowseFixtures.books(30).dropFirst())
            await model.refresh(books, offset: 12)
            #expect(ids(model.list(books, offset: 12)) == ["books-13", "books-14", "books-15", "books-16", "more-16"])
        }
    }

    @Test func aFailedFirstLoadIsRetriedByRefresh() async throws {
        try await withLibrarySettings { settings in
            let service = FakeCarPlayBrowseService()
            service.failsLibraries.value = true
            let (store, model) = await makeBrowse(service, settings: settings)
            #expect(model.status(.libraries) == .failed)
            service.failsLibraries.value = false
            service.libraryList.value = [makeLibrary("books")]
            await model.refresh(.libraries)
            #expect(store.hasLoaded && model.status(.libraries) == .loaded)
            #expect(ids(model.list(.libraries)) == ["books"])
        }
    }

    @Test func aListShowsNoMoreRowUntilItsFirstPageLoads() async throws {
        try await withLibrarySettings { settings in
            let service = FakeCarPlayBrowseService()
            service.libraryList.value = [makeLibrary("books")]
            service.books.value = ["books": BrowseFixtures.books(3)]
            let (_, model) = await makeBrowse(service, settings: settings)
            let books = CarPlayDestination.items(libraryID: "books")

            // The first request is pending: the list is empty, for the loading message.
            service.holdsBooks.value = true
            let load = Task { await model.load(books) }
            while service.heldBooks.value.isEmpty { await Task.yield() }
            #expect(model.status(books) == .loading)
            #expect(model.list(books).rows.isEmpty)

            // It failed: still empty, for the failure message.
            service.holdsBooks.value = false
            service.failsBooks.value = true
            service.releaseBooks()
            await load.value
            #expect(model.status(books) == .failed)
            #expect(model.list(books).rows.isEmpty)

            service.failsBooks.value = false
            await model.refresh(books)
            #expect(model.list(books).rows.count == 3)
        }
    }

    @Test func latestPagesWhoseEpisodesAllDropStillOfferMore() async throws {
        try await withLibrarySettings { settings in
            let service = FakeCarPlayBrowseService()
            service.libraryList.value = [makeLibrary("pods", mediaType: .podcast)]
            // Full pages of episodes with no podcast item, which don't map, then valid ones.
            let unmapped = (0..<2000).map { BrowseFixtures.recent("x\($0)", podcast: "") }
            service.recent.value = ["pods": unmapped + [BrowseFixtures.recent("e1")]]
            let (_, model) = await makeBrowse(service, settings: settings)
            let latest = CarPlayDestination.latestEpisodes(libraryID: "pods")
            await model.load(latest)
            #expect(model.status(latest) == .loaded)
            let rows = model.list(latest).rows
            #expect(rows.count == 1)
            #expect(rows.allSatisfy { if case .more = $0.action { true } else { false } })
        }
    }

    @Test func aRefreshThatEmptiesThePageGoesBackToTheFirst() async throws {
        try await withLibrarySettings { settings in
            let service = FakeCarPlayBrowseService()
            service.libraryList.value = [makeLibrary("books")]
            service.books.value = ["books": BrowseFixtures.books(23)]
            let (_, model) = await makeBrowse(service, settings: settings, limits: CarPlayLimits(maximumItemCount: 5))
            let books = CarPlayDestination.items(libraryID: "books")
            await model.load(books, offset: 8)
            #expect(!model.list(books, offset: 8).rows.isEmpty)
            // A page with rows stays.
            #expect(model.offset(of: books, afterRefreshFrom: 8) == 8)

            // The list shrank below the page: it empties, with no "More…" to leave it.
            service.books.value = ["books": BrowseFixtures.books(3)]
            await model.refresh(books, offset: 8)
            #expect(model.list(books, offset: 8).rows.isEmpty)
            #expect(model.offset(of: books, afterRefreshFrom: 8) == 0)
            #expect(model.list(books, offset: 0).rows.count == 3)
        }
    }

    @Test func aLoadedPageWithNoRowsToShowStillOffersMore() async throws {
        try await withLibrarySettings { settings in
            let service = FakeCarPlayBrowseService()
            service.libraryList.value = [makeLibrary("books")]
            service.series.value = ["books": (0..<25).map { Series(id: "s\($0)", name: "Series \($0)") }]
            // Series rows would open a fourth list, past this depth limit, so none show.
            let (_, model) = await makeBrowse(
                service, settings: settings, limits: CarPlayLimits(maximumItemCount: 5, maximumDepth: 3))
            let series = CarPlayDestination.series(libraryID: "books")
            await model.load(series)
            #expect(model.status(series) == .loaded)
            let rows = model.list(series).rows
            #expect(rows.count == 1)
            #expect(rows.allSatisfy { if case .more = $0.action { true } else { false } })
        }
    }

    @Test func aPodcastOpensItsEpisodesNewestFirstAndTheyPlay() async throws {
        try await withLibrarySettings { settings in
            let service = FakeCarPlayBrowseService()
            let podcast = BrowseFixtures.podcast("pod", episodes: [("old", 1), ("new", 3), ("mid", 2)])
            service.libraryList.value = [makeLibrary("pods", mediaType: .podcast)]
            service.books.value = ["pods": [podcast]]
            service.podcasts.value = ["pod": podcast]
            let (_, model) = await makeBrowse(service, settings: settings)
            let podcasts = CarPlayDestination.items(libraryID: "pods")
            await model.load(podcasts)
            #expect(model.list(podcasts).title == "Podcasts")
            let row = try #require(model.list(podcasts).rows.first)
            let episodes = try #require(model.open(row))
            await model.load(episodes)
            #expect(model.list(episodes).title == "Podcast pod")
            #expect(
                model.list(episodes).rows.map(\.action)
                    == ["new", "mid", "old"].map {
                        .play(itemID: "pod", episodeID: $0)
                    })
        }
    }

    @Test func anotherAccountsStoreShowsAndLoadsNothing() async throws {
        try await withLibrarySettings { settings in
            let service = FakeCarPlayBrowseService()
            service.libraryList.value = [makeLibrary("books")]
            service.books.value = ["books": BrowseFixtures.books(2)]
            let (store, model) = await makeBrowse(service, settings: settings)
            store.clear()
            let books = CarPlayDestination.items(libraryID: "books")
            await model.load(books)
            #expect(model.list(.libraries).rows.isEmpty && model.list(books).rows.isEmpty)
            #expect(!service.requests.value.contains { $0.hasPrefix("books") })
            #expect(model.latestLibraryID == nil)
        }
    }
}
