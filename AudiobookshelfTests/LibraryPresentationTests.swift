import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import Foundation
import SwiftUI
import Testing

@testable import Audiobookshelf

private struct Failure: Error {}

/// A library client serving a book library `lib_a`, a book library `lib_b` and a podcast library `lib_p`, a page at a
/// time. ``hold(_:)`` keeps a library's item requests pending until ``release(_:)``; ``failing`` fails them.
private actor GatedLibraryClient: LibraryService {
    private let items: [String: [ABSCore.LibraryItem]]
    private var holding: Set<String> = []
    private var held: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var requests: [(libraryID: String, query: LibraryQuery)] = []
    var failing = false

    init(items: [String: [ABSCore.LibraryItem]]) {
        self.items = items
    }

    func setFailing(_ failing: Bool) {
        self.failing = failing
    }

    func hold(_ libraryID: String) {
        holding.insert(libraryID)
    }

    func release(_ libraryID: String) {
        holding.remove(libraryID)
        for continuation in held.removeValue(forKey: libraryID) ?? [] { continuation.resume() }
    }

    /// Waits until a request of `libraryID` is held.
    func waitForHeldRequest(_ libraryID: String) async throws {
        var attempts = 0
        while held[libraryID, default: []].isEmpty, attempts < 1_000 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!held[libraryID, default: []].isEmpty)
    }

    func libraries() async throws -> [Library] {
        [
            Library(id: "lib_a", name: "Books A", mediaType: .book),
            Library(id: "lib_b", name: "Books B", mediaType: .book),
            Library(id: "lib_p", name: "Podcasts", mediaType: .podcast),
        ]
    }

    func library(id: String) async throws -> LibraryWithFilterData { throw Failure() }
    func personalizedShelves(libraryID: String) async throws -> [Shelf] { [] }

    func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<ABSCore.LibraryItem> {
        requests.append((libraryID, query))
        if holding.contains(libraryID) {
            await withCheckedContinuation { held[libraryID, default: []].append($0) }
        }
        if failing { throw Failure() }
        let all = items[libraryID] ?? []
        let page = query.page ?? 0
        let limit = query.limit ?? all.count
        let results = Array(all.dropFirst(page * limit).prefix(limit))
        return PagedResults(results: results, total: all.count, limit: limit, page: page)
    }
}

/// A library client whose libraries have one genre, series and author as filter data.
private struct FilterDataClient: LibraryService {
    func libraries() async throws -> [Library] { [] }
    func personalizedShelves(libraryID: String) async throws -> [Shelf] { [] }
    func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<ABSCore.LibraryItem> {
        PagedResults(results: [], total: 0, limit: 0, page: 0)
    }

    func library(id: String) async throws -> LibraryWithFilterData {
        LibraryWithFilterData(
            library: Library(id: id, name: "Books", mediaType: .book),
            filterData: LibraryFilterData(
                authors: [Author(id: "aut_1", name: "Jane Austen")], series: [Series(id: "ser_1", name: "Barsoom")],
                genres: ["Fantasy"]))
    }
}

/// `count` books of `libraryID`, with IDs `<prefix>0`, `<prefix>1`, ….
private func books(_ prefix: String, _ count: Int, in libraryID: String) -> [ABSCore.LibraryItem] {
    (0..<count).map {
        ABSCore.LibraryItem(
            id: "\(prefix)\($0)", libraryId: libraryID, mediaType: .book, media: SampleLibrary.emma.media)
    }
}

private let account = LibraryConnectionKey(
    connectionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA") ?? UUID(), userID: "user-1")
private let otherAccount = LibraryConnectionKey(
    connectionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB") ?? UUID(), userID: "user-2")

/// A store connected to `client` with settings in a throwaway defaults suite, so a test never touches the app's.
@MainActor
private func withStore(
    _ client: GatedLibraryClient, _ body: (LibraryStore) async throws -> Void
) async throws {
    let suiteName = "LibraryPresentationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = LibraryStore(settings: AppSettings(defaults: defaults))
    await store.connect(client: client, connectionKey: account)
    try await body(store)
}

/// The host the screen's task builds for `libraryID` (replacing `host`), with the library's type from the store.
@MainActor
private func makeHost(
    _ store: LibraryStore, _ libraryID: String, replacing host: LibraryModelHost? = nil
) throws -> (key: BrowseModelKey, host: LibraryModelHost) {
    let key = try #require(BrowseModelKey(store: store, libraryID: libraryID))
    let updated = LibraryPresentation.updated(
        host, for: key, mediaType: store.mediaType(libraryID: libraryID), store: store)
    return (key, try #require(updated))
}

/// The IDs of the items the screen shows for `key` with `host`, as `LibraryView` looks its model up.
@MainActor
private func shownIDs(_ host: LibraryModelHost?, for key: BrowseModelKey) -> [String] {
    host?.model(for: key)?.items.map(\.id) ?? []
}

@MainActor
@Suite struct LibraryPresentationTests {
    @Test func modelUsesTheSavedPreferencesAndSavesChangesForItsAccount() async throws {
        let client = GatedLibraryClient(items: ["lib_a": books("a", 3, in: "lib_a")])
        try await withStore(client) { store in
            store.saveViewPreferences(
                LibraryViewPreferences(viewMode: .list, collapseSeries: true), libraryID: "lib_a",
                connectionKey: account)
            let (_, host) = try makeHost(store, "lib_a")
            let model = host.model
            #expect(model.preferences.viewMode == .list)
            await model.load()?.value
            let request = try #require(await client.requests.first)
            #expect(request.libraryID == "lib_a")
            #expect(request.query.collapseSeries)
            #expect(request.query.limit == 20)

            await model.update { $0.viewMode = .grid }?.value
            #expect(store.viewPreferences(libraryID: "lib_a")?.viewMode == .grid)

            // A model left over from another account never writes into the new one.
            await store.connect(client: client, connectionKey: otherAccount)
            model.update { $0.viewMode = .list }
            #expect(store.viewPreferences(libraryID: "lib_a") == nil)
        }
    }

    @Test func hostWaitsForTheLibraryTypeAndKeepsItsModelForItsKey() async throws {
        let client = GatedLibraryClient(items: [:])
        try await withStore(client) { store in
            let key = try #require(BrowseModelKey(store: store, libraryID: "lib_a"))
            #expect(LibraryPresentation.updated(nil, for: key, mediaType: nil, store: store) == nil)
            #expect(LibraryPresentation.updated(nil, for: nil, mediaType: .book, store: store) == nil)
            #expect(LibraryPresentation.updated(nil, for: key, mediaType: .book, store: nil) == nil)

            let (_, built) = try makeHost(store, "lib_a")
            #expect(built.model.mediaType == .book)
            let kept = LibraryPresentation.updated(built, for: key, mediaType: .book, store: store)
            #expect(kept?.model === built.model)
            // The type became unknown for a moment: the model built for the key stays.
            let unknown = LibraryPresentation.updated(built, for: key, mediaType: nil, store: store)
            #expect(unknown?.model === built.model)
            // Another type for the same library gets a model with that type's sorts and filters.
            let retyped = LibraryPresentation.updated(built, for: key, mediaType: .podcast, store: store)
            #expect(retyped?.model !== built.model)
            #expect(retyped?.model.mediaType == .podcast)

            let (podcastKey, podcasts) = try makeHost(store, "lib_p", replacing: built)
            #expect(podcasts.key == podcastKey)
            #expect(podcasts.model.mediaType == .podcast)
            #expect(podcasts.model !== built.model)
        }
    }

    @Test func statesFollowTheGatedPages() async throws {
        let client = GatedLibraryClient(items: ["lib_a": books("a", 3, in: "lib_a")])
        try await withStore(client) { store in
            let (_, host) = try makeHost(store, "lib_a")
            let model = host.model
            #expect(LibraryPresentation.state(of: model) == .loading)

            await client.hold("lib_a")
            let load = model.load()
            try await client.waitForHeldRequest("lib_a")
            #expect(LibraryPresentation.state(of: model) == .loading)
            await client.setFailing(true)
            await client.release("lib_a")
            await load?.value
            #expect(LibraryPresentation.state(of: model) == .failed)

            await client.setFailing(false)
            await BrowsePresentation.retry(model.list)?.value
            #expect(LibraryPresentation.state(of: model) == .loaded(failed: false))
            #expect(model.items.map(\.id) == ["a0", "a1", "a2"])

            // A failed refresh keeps the items, with the failure above them.
            await client.setFailing(true)
            #expect(await BrowsePresentation.refresh(model.list))
            #expect(LibraryPresentation.state(of: model) == .loaded(failed: true))
            #expect(model.items.count == 3)
        }
    }

    @Test func emptyAndSignedOutStates() async throws {
        let client = GatedLibraryClient(items: [:])
        try await withStore(client) { store in
            let (_, host) = try makeHost(store, "lib_b")
            await host.model.load()?.value
            #expect(LibraryPresentation.state(of: host.model) == .empty)
            #expect(
                LibraryPresentation.countText(total: host.model.total, mediaType: .book, locale: english) == "0 books")

            store.clear()
            #expect(BrowseModelKey(store: store, libraryID: "lib_b") == nil)
            #expect(BrowseScreenState.placeholder(store: store, libraryID: "lib_b") == .signedOut)
        }
        #expect(BrowseScreenState.placeholder(store: nil, libraryID: "lib_a") == .signedOut)
    }

    @Test func itemsNearTheEndLoadTheNextPage() async throws {
        let client = GatedLibraryClient(items: ["lib_a": books("a", 25, in: "lib_a")])
        try await withStore(client) { store in
            let model = try makeHost(store, "lib_a").host.model
            await model.load()?.value
            #expect(model.items.count == 20)
            #expect(LibraryPresentation.countText(total: model.total, mediaType: .book, locale: english) == "25 books")

            model.list.itemAppeared(id: "a10")
            #expect(!model.isLoading)
            #expect(await client.requests.count == 1)

            model.list.itemAppeared(id: "a15")
            #expect(model.isLoading)
            // The page in flight.
            await model.list.loadNextPage()?.value
            #expect(model.items.count == 25)
            #expect(model.reachedEnd)
            #expect(await client.requests.map { $0.query.page } == [0, 1])
        }
    }

    /// Negative control: comparing only the library ID in ``LibraryPresentation/updated(_:for:mediaType:store:)`` keeps
    /// the first account's model, and this test fails.
    @Test func accountSwitchWithTheSameLibraryGetsANewModelWithThatAccountsPreferences() async throws {
        let client = GatedLibraryClient(items: ["lib_a": books("a", 3, in: "lib_a")])
        try await withStore(client) { store in
            store.saveViewPreferences(
                LibraryViewPreferences(viewMode: .list), libraryID: "lib_a", connectionKey: account)
            let (firstKey, first) = try makeHost(store, "lib_a")
            await first.model.load()?.value
            #expect(first.model.preferences.viewMode == .list)

            await store.connect(client: client, connectionKey: otherAccount)
            store.saveViewPreferences(
                LibraryViewPreferences(sort: .title, descending: false), libraryID: "lib_a",
                connectionKey: otherAccount)
            let (key, second) = try makeHost(store, "lib_a", replacing: first)
            #expect(key.libraryID == firstKey.libraryID)
            #expect(key.connection == otherAccount)
            #expect(second.model !== first.model)
            #expect(second.model.list.connectionKey == otherAccount)
            #expect(second.model.preferences.viewMode == .grid)
            #expect(second.model.preferences.sort == .title)
            #expect(shownIDs(first, for: key).isEmpty)
        }
    }

    @Test func pagingFollowsTheGridsColumns() {
        let defaults = LibraryPaging(pageSize: 20, prefetchThreshold: 5)
        #expect(LibraryPresentation.paging(columns: 0) == defaults)
        #expect(LibraryPresentation.paging(columns: 1) == defaults)
        #expect(LibraryPresentation.paging(columns: 3) == LibraryPaging(pageSize: 20, prefetchThreshold: 6))
        #expect(LibraryPresentation.paging(columns: 5) == LibraryPaging(pageSize: 20, prefetchThreshold: 10))
        #expect(LibraryPresentation.paging(columns: 10) == LibraryPaging(pageSize: 40, prefetchThreshold: 20))
        #expect(LibraryPresentation.paging(columns: 16) == LibraryPaging(pageSize: 64, prefetchThreshold: 32))

        // Widths as `ItemGrid` fits 140-point cells with 16-point spacing and padding.
        let paging = { (width: CGFloat?, size: DynamicTypeSize, mode: LibraryViewMode) in
            LibraryPresentation.paging(width: width, dynamicTypeSize: size, viewMode: mode)
        }
        #expect(ItemGridMetrics.columnCount(width: 375, dynamicTypeSize: .large) == 2)
        #expect(ItemGridMetrics.columnCount(width: 1_440, dynamicTypeSize: .large) == 9)
        #expect(ItemGridMetrics.columnCount(width: 0, dynamicTypeSize: .large) == 1)
        #expect(paging(nil, .large, .grid) == defaults)
        #expect(paging(375, .large, .grid) == defaults)
        #expect(paging(1_440, .large, .grid) == LibraryPaging(pageSize: 36, prefetchThreshold: 18))
        #expect(paging(2_400, .large, .grid) == LibraryPaging(pageSize: 60, prefetchThreshold: 30))
        // Larger text gets fewer, wider columns; the list is one column at any width.
        #expect(paging(1_440, .accessibility3, .grid) == LibraryPaging(pageSize: 24, prefetchThreshold: 12))
        #expect(paging(2_400, .large, .list) == defaults)
    }

    @Test func wideGridPrefetchesTwoRowsBeforeTheEnd() async throws {
        let client = GatedLibraryClient(items: ["lib_a": books("a", 50, in: "lib_a")])
        try await withStore(client) { store in
            let model = try makeHost(store, "lib_a").host.model
            LibraryPresentation.paging(columns: 10).apply(to: model)
            await model.load()?.value
            #expect(model.items.count == 40)

            // Index 19 is 21 from the end of 40: not yet. Index 20 is the threshold, 20 from the end.
            model.list.itemAppeared(id: "a19")
            #expect(!model.isLoading)
            model.list.itemAppeared(id: "a20")
            #expect(model.isLoading)
            await model.list.loadNextPage()?.value
            #expect(model.items.count == 50)
            #expect(await client.requests.map { $0.query.limit } == [40, 40])
            #expect(await client.requests.map { $0.query.page } == [0, 1])
        }
    }

    @Test func collapsedSeriesOpensTheSeries() async throws {
        let collapsed = ABSCore.LibraryItem(
            id: "a0", libraryId: "lib_a", mediaType: .book, media: SampleLibrary.princessOfMars.media,
            collapsedSeries: CollapsedSeries(id: "ser_barsoom", name: "Barsoom", numBooks: 3))
        let client = GatedLibraryClient(items: ["lib_a": [collapsed] + books("b", 1, in: "lib_a")])
        try await withStore(client) { store in
            let model = try makeHost(store, "lib_a").host.model
            await model.load()?.value
            let entries = model.items
            #expect(entries.map(\.kind) == [.series, .book])
            #expect(ItemCardActions.route(for: entries[0]) == .series(id: "ser_barsoom"))
            #expect(ItemCardActions.route(for: entries[1]) == .item(id: "b0"))

            let router = Router()
            router.selectedTab = .library
            BrowsePresentation.open(ItemCardActions.route(for: entries[0]), in: router)
            #expect(router[path: .library] == [.series(id: "ser_barsoom")])
        }
    }

    /// Negative control: removing the key check in ``BrowseModelHost/model(for:)`` shows library A's items while the
    /// router is on library B, and this test fails.
    @Test func librarySwitchWithAPageInFlightNeverShowsTheOldLibrarysItems() async throws {
        let client = GatedLibraryClient(
            items: ["lib_a": books("a", 25, in: "lib_a"), "lib_b": books("b", 3, in: "lib_b")])
        try await withStore(client) { store in
            let (keyA, hostA) = try makeHost(store, "lib_a")
            await hostA.model.load()?.value
            #expect(shownIDs(hostA, for: keyA).count == 20)

            // Library A's second page is in flight when the router switches to library B.
            await client.hold("lib_a")
            let pageA = hostA.model.list.loadNextPage()
            try await client.waitForHeldRequest("lib_a")
            let keyB = try #require(BrowseModelKey(store: store, libraryID: "lib_b"))
            // Before the screen's task replaces the model, B shows the placeholder, not A's items.
            #expect(shownIDs(hostA, for: keyB).isEmpty)

            let (_, hostB) = try makeHost(store, "lib_b", replacing: hostA)
            #expect(hostB.model !== hostA.model)
            await hostB.model.load()?.value
            #expect(shownIDs(hostB, for: keyB) == ["b0", "b1", "b2"])

            // A's page lands late, in A's model only.
            await client.release("lib_a")
            await pageA?.value
            #expect(shownIDs(hostB, for: keyB) == ["b0", "b1", "b2"])
            #expect(shownIDs(hostA, for: keyB).isEmpty)
            #expect(
                LibraryPresentation.countText(total: hostB.model.total, mediaType: .book, locale: english) == "3 books")
        }
    }

    @Test func countTextSaysBooksOrPodcasts() {
        #expect(LibraryPresentation.countText(total: nil, mediaType: .book) == nil)
        #expect(LibraryPresentation.countText(total: 1, mediaType: .book, locale: english) == "1 book")
        #expect(LibraryPresentation.countText(total: 1_234, mediaType: .book, locale: english) == "1,234 books")
        #expect(LibraryPresentation.countText(total: 1, mediaType: .podcast, locale: english) == "1 Podcast")
        #expect(LibraryPresentation.countText(total: 7, mediaType: .podcast, locale: english) == "7 Podcasts")
    }

    @Test func everyMessageKeyIsInTheCatalog() {
        #expect(LibraryPresentation.messages(for: .podcast).empty == "MessageNoPodcastsFound")
        #expect(LibraryPresentation.messages(for: .book).empty == "MessageNoItemsFound")
        #expect(LibraryPresentation.messages(for: nil).empty == "MessageNoItemsFound")
        let messages = [LibraryPresentation.messages(for: .book), LibraryPresentation.messages(for: .podcast)]
        let keys =
            messages.flatMap { [$0.failed, $0.empty] }
            + ["SharedBookCount", "LabelPodcast", "LabelPodcasts"]
        for key in keys {
            #expect(L10n.string(key) != key, "\(key) isn't in the catalog")
        }
    }

    @Test func podcastSortMenuHasNoProgressOrDurationKeys() {
        let podcast = LibraryPresentation.sortOptions(for: .podcast, preferences: LibraryViewPreferences()).map(\.key)
        #expect(podcast == LibrarySortKey.podcastKeys)
        for key in [LibrarySortKey.progress, .progressStarted, .progressFinished, .duration] {
            #expect(!podcast.contains(key))
        }
        let books = LibraryPresentation.sortOptions(for: .book, preferences: LibraryViewPreferences()).map(\.key)
        #expect(books == LibrarySortKey.bookKeys)
        #expect(!books.contains(.episodeCount) && !books.contains(.podcastAuthor))
    }

    @Test func sortMenuMarksTheSelectedKeyWithItsDirection() {
        let options = LibraryPresentation.sortOptions(
            for: .book, preferences: LibraryViewPreferences(sort: .title, descending: false))
        #expect(options.filter(\.isSelected).map(\.key) == [.title])
        #expect(options.compactMap(\.arrowSymbol) == ["arrow.up"])
        let descending = LibraryPresentation.sortOptions(for: .book, preferences: LibraryViewPreferences())
        #expect(descending.first { $0.isSelected }?.key == .addedAt)
        #expect(descending.compactMap(\.arrowSymbol) == ["arrow.down"])
    }

    /// Each choice reloads; the test waits for each reload (`load()` returns the one in flight),
    /// as a reload the next choice cancelled can still reach the client after it.
    @Test func choosingASortFlipsOrSetsTheDirectionAndSavesIt() async throws {
        let client = GatedLibraryClient(items: ["lib_a": books("a", 3, in: "lib_a")])
        try await withStore(client) { store in
            let model = try makeHost(store, "lib_a").host.model
            #expect(model.preferences.sort == .addedAt && model.preferences.descending)

            LibraryPresentation.selectSort(.addedAt, in: model)
            #expect(model.preferences.sort == .addedAt && !model.preferences.descending)
            await model.load()?.value
            LibraryPresentation.selectSort(.title, in: model)
            #expect(model.preferences.sort == .title && !model.preferences.descending)
            await model.load()?.value
            LibraryPresentation.selectSort(.title, in: model)
            #expect(model.preferences.descending)
            await model.load()?.value

            let saved = try #require(store.viewPreferences(libraryID: "lib_a"))
            #expect(saved.sort == .title && saved.descending)
            let requests = await client.requests.map { [$0.query.sort, "\($0.query.descending)"] }
            #expect(
                requests == [
                    [LibrarySortKey.addedAt.rawValue, "false"], [LibrarySortKey.title.rawValue, "false"],
                    [LibrarySortKey.title.rawValue, "true"],
                ])
        }
    }

    @Test func filterValuesAreLocalizedWithNoSeriesFirst() async throws {
        let filterModel = LibraryFilterModel(client: FilterDataClient(), locale: english)
        await filterModel.load(libraryID: "lib_a")?.value
        let choices = try #require(filterModel.choices)
        let series = LibraryPresentation.filterValues(for: .series, choices: choices, locale: english)
        #expect(series?.map(\.id) == ["no-series", "ser_1"])
        #expect(series?.first?.name == L10n.string("MessageNoSeries", locale: english))
        #expect(
            LibraryPresentation.filterValues(for: .progress, choices: nil, locale: english)?.map(\.name)
                == ["Finished", "In Progress", "Not Started", "Not Finished"])
        #expect(
            LibraryPresentation.filterValues(for: .ebooks, choices: nil, locale: english)?.map(\.id)
                == ["ebook", "supplementary"])
        // Groups from the filter data wait for it; groups without values have none.
        #expect(LibraryPresentation.filterValues(for: .genres, choices: nil) == nil)
        for group in LibraryFilterGroup.allCases where !group.needsValue {
            #expect(LibraryPresentation.filterValues(for: group, choices: nil)?.isEmpty == true)
        }

        #expect(LibraryPresentation.filterSummary(nil, choices: nil, locale: english) == "All")
        #expect(
            LibraryPresentation.filterSummary(.init(group: .authors, value: "aut_1"), choices: choices, locale: english)
                == "Author, Jane Austen")
        #expect(
            LibraryPresentation.filterSummary(.init(group: .authors, value: "aut_1"), choices: nil, locale: english)
                == "Author")
        #expect(
            LibraryPresentation.filterSummary(
                .init(group: .narrators, value: "Stephen Fry"), choices: nil, locale: english)
                == "Narrator, Stephen Fry")
        #expect(
            LibraryPresentation.filterSummary(.init(group: .explicit), choices: nil, locale: english) == "Explicit")
        // Values that need no filter data are named before the choices load.
        let noSeries = LibraryViewPreferences.Filter(group: .series, value: LibraryFilterModel.Choice.noSeries.id)
        #expect(
            LibraryPresentation.filterSummary(noSeries, choices: nil, locale: english)
                == "Series, No series")
        #expect(
            LibraryPresentation.filterSummary(
                .init(group: .progress, value: "in-progress"), choices: nil, locale: english)
                == "Progress, In Progress")
        #expect(
            LibraryPresentation.filterSummary(
                .init(group: .ebooks, value: "supplementary"), choices: nil, locale: english)
                == "Ebooks, \(L10n.string("LabelHasSupplementaryEbook", locale: english))")

        // Only an author's or series' name needs the choices before the sheet opens.
        #expect(LibraryPresentation.loadsFilterChoicesEarly(for: .init(group: .authors, value: "aut_1")))
        #expect(LibraryPresentation.loadsFilterChoicesEarly(for: .init(group: .series, value: "ser_1")))
        #expect(!LibraryPresentation.loadsFilterChoicesEarly(for: .init(group: .series, value: "no-series")))
        #expect(!LibraryPresentation.loadsFilterChoicesEarly(for: .init(group: .genres, value: "Fantasy")))
        #expect(!LibraryPresentation.loadsFilterChoicesEarly(for: nil))
    }

    @Test func choosingAFilterViewOrCollapseSavesIt() async throws {
        let client = GatedLibraryClient(items: ["lib_a": books("a", 3, in: "lib_a")])
        try await withStore(client) { store in
            let model = try makeHost(store, "lib_a").host.model
            await model.update { $0.filter = .init(group: .feedOpen) }?.value
            #expect(await client.requests.last?.query.filter == LibraryFilter(group: "feed-open"))
            // The filter in use again is the same query: nothing reloads (`update` returns no load).
            #expect(model.update { $0.filter = .init(group: .feedOpen) } == nil)
            await model.update { $0.collapseSeries = true }?.value
            #expect(await client.requests.last?.query.collapseSeries == true)
            // Grid or list is the same query: nothing reloads.
            #expect(model.update { $0.viewMode = .list } == nil)
            let saved = try #require(store.viewPreferences(libraryID: "lib_a"))
            #expect(saved.filter == .init(group: .feedOpen) && saved.collapseSeries && saved.viewMode == .list)

            await model.update { $0.filter = .init(group: .authors, value: "aut_1") }?.value
            #expect(await client.requests.last?.query.filter == LibraryFilter(group: "authors", value: "aut_1"))
            #expect(!LibraryPresentation.isCollapseSeriesDisabled(model.preferences))

            // The server ignores collapsing while filtering by series: the toggle is off and changes no query.
            await model.update { $0.filter = .init(group: .series, value: "ser_1") }?.value
            #expect(await client.requests.last?.query.collapseSeries == false)
            #expect(LibraryPresentation.isCollapseSeriesDisabled(model.preferences))
            #expect(model.update { $0.collapseSeries = false } == nil)

            await model.update { $0.filter = nil }?.value
            #expect(await client.requests.last?.query.filter == nil)
            #expect(store.viewPreferences(libraryID: "lib_a")?.filter == nil)
        }
        #expect(LibraryPresentation.showsCollapseSeries(for: .book))
        #expect(!LibraryPresentation.showsCollapseSeries(for: .podcast))
    }

    @Test func everySortKeyAndFilterGroupHasACatalogKey() {
        let keys =
            LibrarySortKey.allCases.map(LibraryPresentation.titleKey(for:))
            + LibraryFilterGroup.allCases.map(LibraryPresentation.titleKey(for:))
            + LibraryFilterModel.ProgressState.allCases.map(LibraryPresentation.titleKey(for:))
            + LibraryFilterModel.EbookKind.allCases.map(LibraryPresentation.titleKey(for:))
            + LibraryPresentation.viewModes.map(LibraryPresentation.titleKey(for:))
            + [true, false].map(LibraryPresentation.directionKey(descending:))
            + [
                "HeaderLibrarySort", "HeaderLibraryFilter", "ButtonLibraryFilterDone", "ButtonClearFilter",
                "LabelLibraryViewOptions", "LabelCollapseSeries", "LabelAll", "MessageNoSeries",
                "MessageLibraryFilterLoadFailed", "MessageLibraryFilterNoValues", "ButtonRetry", "MessageLoading",
            ]
        for key in keys {
            #expect(L10n.string(key) != key, "\(key) isn't in the catalog")
            #expect(L10n.string(key, locale: english) != key, "\(key) isn't in the English catalog")
        }
        // Negative control: a key the catalog lacks comes back as itself, so the checks above can fail.
        #expect(L10n.string("LabelLibraryNoSuchKey") == "LabelLibraryNoSuchKey")
    }
}

private let english = Locale(identifier: "en_US")
