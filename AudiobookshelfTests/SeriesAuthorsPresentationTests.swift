import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import Foundation
import Synchronization
import Testing

@testable import Audiobookshelf

private struct Failure: Error {}

/// A library client that serves the sample series, authors and Barsoom books, records what the
/// screens ask for, and fails the series and author requests while `fails` is set.
private final class FakeSeriesAuthorsClient: LibraryService, SeriesAuthorsService {
    let failsLibraries: Bool
    let fails = Mutex(false)
    /// The library of the author and the books; the others have none of them.
    let libraryID: String
    /// The books a series or author request returns, in server order.
    let books: [LibraryItem]
    let seriesRequests = Mutex<[(libraryID: String, query: LibraryQuery)]>([])
    let bookRequests = Mutex<[(libraryID: String, query: LibraryQuery)]>([])

    init(
        failsLibraries: Bool = false, libraryID: String = "lib_a",
        books: [LibraryItem] = [
            barsoom(SampleLibrary.princessOfMars, "1"), barsoom(SampleLibrary.godsOfMars, "2"),
            barsoom(SampleLibrary.warlordOfMars, "3"),
        ]
    ) {
        self.failsLibraries = failsLibraries
        self.libraryID = libraryID
        self.books = books
    }

    func libraries() async throws -> [Library] {
        if failsLibraries { throw Failure() }
        return []
    }

    func library(id: String) async throws -> LibraryWithFilterData { throw Failure() }
    func personalizedShelves(libraryID: String) async throws -> [Shelf] { [] }
    func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> { throw Failure() }

    func seriesPage(libraryID: String, query: LibraryQuery) async throws -> PagedResults<Series> {
        seriesRequests.withLock { $0.append((libraryID, query)) }
        try check()
        let series = SampleLibrary.series
        return PagedResults(results: series, total: series.count, limit: query.limit ?? 0, page: query.page ?? 0)
    }

    func authorList(libraryID: String) async throws -> [Author] {
        try check()
        return SampleLibrary.authors
    }

    func seriesDetail(id: String) async throws -> SeriesDetailResponse {
        try check()
        guard id == "ser_barsoom" else { throw APIError.notFound }
        return SeriesDetailResponse(series: Series(id: id, name: "Barsoom", libraryId: "lib_a"))
    }

    func authorDetail(id: String) async throws -> AuthorDetailResponse {
        try check()
        guard id == "aut_burroughs" else { throw APIError.notFound }
        return AuthorDetailResponse(
            author: Author(id: id, name: "Edgar Rice Burroughs", libraryId: libraryID, numBooks: 3))
    }

    func filteredBooksPage(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> {
        bookRequests.withLock { $0.append((libraryID, query)) }
        try check()
        let books = libraryID == self.libraryID ? books : []
        return PagedResults(results: books, total: books.count, limit: query.limit ?? 0, page: query.page ?? 0)
    }

    private func check() throws {
        if fails.withLock({ $0 }) { throw Failure() }
    }
}

/// `item` as the series-filtered list sends it: with the series and the item's sequence.
private func barsoom(_ item: LibraryItem, _ sequence: String) -> LibraryItem {
    LibraryItem(
        id: item.id, libraryId: item.libraryId, isMissing: item.isMissing, mediaType: item.mediaType,
        media: item.media, series: Series(id: "ser_barsoom", name: "Barsoom", sequence: sequence))
}

private let account = LibraryConnectionKey(
    connectionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA") ?? UUID(), userID: "user-1")
private let otherAccount = LibraryConnectionKey(
    connectionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB") ?? UUID(), userID: "user-2")

/// A store connected to `client` with settings in a throwaway defaults suite, so a test never touches the app's.
@MainActor
private func withStore(
    _ client: FakeSeriesAuthorsClient = FakeSeriesAuthorsClient(), _ body: (LibraryStore) async throws -> Void
) async throws {
    let suiteName = "SeriesAuthorsPresentationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = LibraryStore(settings: AppSettings(defaults: defaults))
    await store.connect(client: client, connectionKey: account)
    try await body(store)
}

/// The services and key a screen builds its model from.
@MainActor
private func keyAndServices(
    _ store: LibraryStore, libraryID: String = "lib_a", entityID: String? = nil
) throws -> (key: BrowseModelKey, services: LibraryStoreServices) {
    let key = try #require(BrowseModelKey(store: store, libraryID: libraryID, entityID: entityID))
    return (key, try #require(store.makeServices()))
}

private func book(_ id: String, kind: ItemKind = .book, episodeID: String? = nil, seriesID: String? = nil)
    -> ItemSummary
{
    ItemSummary(
        id: id, itemID: id, episodeID: episodeID, seriesID: seriesID, kind: kind, title: "Title \(id)",
        duration: 60)
}

@MainActor
@Suite struct BrowseScreenStateTests {
    private typealias Inputs = BrowseScreenState.Inputs

    @Test func resolvesEveryCombination() {
        // Before the first load finishes: loading, or Retry once it failed.
        #expect(BrowseScreenState.resolve(Inputs()) == .loading)
        #expect(BrowseScreenState.resolve(Inputs(isLoading: true)) == .loading)
        #expect(BrowseScreenState.resolve(Inputs(hasError: true)) == .failed)
        #expect(BrowseScreenState.resolve(Inputs(isLoading: true, hasError: true)) == .loading)
        // Loaded.
        #expect(BrowseScreenState.resolve(Inputs(hasLoaded: true)) == .empty)
        #expect(BrowseScreenState.resolve(Inputs(hasLoaded: true, hasError: true)) == .failed)
        #expect(BrowseScreenState.resolve(Inputs(hasLoaded: true, hasContent: true)) == .loaded(failed: false))
        #expect(
            BrowseScreenState.resolve(Inputs(hasLoaded: true, hasContent: true, isLoading: true))
                == .loaded(failed: false))
        #expect(
            BrowseScreenState.resolve(Inputs(hasLoaded: true, hasContent: true, hasError: true))
                == .loaded(failed: true))
        // A 404 wins over anything loaded before.
        #expect(BrowseScreenState.resolve(Inputs(isNotFound: true)) == .notFound)
        #expect(
            BrowseScreenState.resolve(Inputs(hasLoaded: true, hasContent: true, hasError: true, isNotFound: true))
                == .notFound)
    }

    @Test func pagedListGoesFromLoadingToLoadedAndKeepsItsItemsWhenAPageFails() async throws {
        let client = FakeSeriesAuthorsClient()
        try await withStore(client) { store in
            let (key, services) = try keyAndServices(store)
            let list = SeriesPresentation.makeList(key: key, services: services)
            #expect(BrowseScreenState.resolve(list: list) == .loading)

            client.fails.withLock { $0 = true }
            await list.loadNextPage()?.value
            #expect(BrowseScreenState.resolve(list: list) == .failed)

            client.fails.withLock { $0 = false }
            await BrowsePresentation.retry(list)?.value
            #expect(BrowseScreenState.resolve(list: list) == .loaded(failed: false))
            #expect(list.reachedEnd)

            // At the end, Retry refreshes: the next page would load nothing and keep the error.
            client.fails.withLock { $0 = true }
            await list.refresh()?.value
            #expect(BrowseScreenState.resolve(list: list) == .loaded(failed: true))
            #expect(list.loadNextPage() == nil)
            let requests = client.seriesRequests.withLock { $0.count }
            client.fails.withLock { $0 = false }
            await BrowsePresentation.retry(list)?.value
            #expect(client.seriesRequests.withLock { $0.count } == requests + 1)
            #expect(BrowseScreenState.resolve(list: list) == .loaded(failed: false))
        }
    }

    @Test func pagedListThatLoadsNothingIsEmpty() async throws {
        try await withStore(FakeSeriesAuthorsClient(books: [])) { store in
            let (key, services) = try keyAndServices(store, entityID: "aut_burroughs")
            let model = AuthorsPresentation.makeDetail(authorID: "aut_burroughs", key: key, services: services)
            await model.loadIfNeeded()
            #expect(AuthorsPresentation.state(of: model) == .loaded(failed: false))
            #expect(BrowseScreenState.resolve(list: model.books) == .empty)
        }
    }

    @Test func placeholderIsSignedOutWithoutAnAccount() async throws {
        #expect(BrowseScreenState.placeholder(store: nil, libraryID: "lib_a") == .signedOut)
        try await withStore { store in
            store.clear()
            #expect(BrowseScreenState.placeholder(store: store, libraryID: "lib_a") == .signedOut)
        }
    }

    @Test func placeholderWaitsForALibrary() async throws {
        try await withStore { store in
            #expect(BrowseScreenState.placeholder(store: store, libraryID: "lib_a") == .loading)
            #expect(BrowseScreenState.placeholder(store: store, libraryID: nil) == .empty)
        }
        try await withStore(FakeSeriesAuthorsClient(failsLibraries: true)) { store in
            #expect(BrowseScreenState.placeholder(store: store, libraryID: nil) == .failed)
        }
    }
}

@MainActor
@Suite struct BrowseModelKeyTests {
    @Test func keyNeedsAStoreAnAccountAndALibrary() async throws {
        #expect(BrowseModelKey(store: nil, libraryID: "lib_a") == nil)
        try await withStore { store in
            #expect(BrowseModelKey(store: store, libraryID: nil) == nil)
            #expect(BrowseModelKey(store: store, libraryID: "lib_a") != nil)
            store.clear()
            #expect(BrowseModelKey(store: store, libraryID: "lib_a") == nil)
        }
    }

    @Test func anotherLibraryEntityOrStoreGetsAnotherKey() async throws {
        try await withStore { store in
            try await withStore { other in
                let key = BrowseModelKey(store: store, libraryID: "lib_a", entityID: "ser_1")
                #expect(key == BrowseModelKey(store: store, libraryID: "lib_a", entityID: "ser_1"))
                #expect(key != BrowseModelKey(store: store, libraryID: "lib_b", entityID: "ser_1"))
                #expect(key != BrowseModelKey(store: store, libraryID: "lib_a", entityID: "ser_2"))
                #expect(key != BrowseModelKey(store: other, libraryID: "lib_a", entityID: "ser_1"))
            }
        }
    }

    @Test func hostServesItsModelOnlyForItsKey() async throws {
        try await withStore { store in
            let key = try #require(BrowseModelKey(store: store, libraryID: "lib_a"))
            let make = { (services: LibraryStoreServices) in AuthorsModel(libraryID: "lib_a", service: services) }
            let host = try #require(BrowseModelHost(key: key, store: store, make: make))
            #expect(host.model(for: key) === host.model)
            #expect(host.model(for: BrowseModelKey(store: store, libraryID: "lib_b")) == nil)
            #expect(host.model(for: nil) == nil)

            // Signed out: no services, so no model.
            store.clear()
            let signedOut = BrowseModelHost(key: key, store: store, make: make)
            #expect(signedOut == nil)
        }
    }

    @Test func updatedKeepsTheHostForItsKeyAndReplacesItOtherwise() async throws {
        try await withStore { store in
            let makeAuthors = { (key: BrowseModelKey, services: LibraryStoreServices, _: ProgressCache) in
                AuthorsModel(libraryID: key.libraryID, service: services)
            }
            let key = try #require(BrowseModelKey(store: store, libraryID: "lib_a"))
            let host = try #require(BrowseModelHost.updated(nil, for: key, store: store, make: makeAuthors))
            #expect(host.key == key)
            #expect(host.model.libraryID == "lib_a")

            let same = BrowseModelHost.updated(host, for: key, store: store, make: makeAuthors)
            #expect(same?.model === host.model)

            let otherLibrary = BrowseModelKey(store: store, libraryID: "lib_b")
            let replaced = try #require(
                BrowseModelHost.updated(host, for: otherLibrary, store: store, make: makeAuthors))
            #expect(replaced.model !== host.model)
            #expect(replaced.key == otherLibrary)
            #expect(replaced.model.libraryID == "lib_b")

            #expect(BrowseModelHost.updated(host, for: nil, store: store, make: makeAuthors) == nil)
            #expect(BrowseModelHost.updated(host, for: key, store: nil, make: makeAuthors) == nil)
        }
    }

    @Test func storeReconnectedAsAnotherAccountGetsAnotherModel() async throws {
        try await withStore { store in
            let makeAuthors = { (key: BrowseModelKey, services: LibraryStoreServices, _: ProgressCache) in
                AuthorsModel(libraryID: key.libraryID, service: services)
            }
            let key = try #require(BrowseModelKey(store: store, libraryID: "lib_a"))
            let host = try #require(BrowseModelHost.updated(nil, for: key, store: store, make: makeAuthors))

            await store.connect(client: FakeSeriesAuthorsClient(), connectionKey: otherAccount)
            let newKey = try #require(BrowseModelKey(store: store, libraryID: "lib_a"))
            #expect(newKey != key)
            #expect(newKey.connection == otherAccount)
            #expect(host.model(for: newKey) == nil)
            // The store's services are the other account's, so a model for the old key isn't built.
            let stale = BrowseModelHost(key: key, store: store) { makeAuthors(key, $0, store.progress) }
            #expect(stale == nil)
            let replaced = BrowseModelHost.updated(host, for: newKey, store: store, make: makeAuthors)
            #expect(replaced?.key == newKey)
            #expect(replaced?.model !== host.model)
        }
    }
}

@MainActor
@Suite struct BrowsePresentationTests {
    @Test func openPushesOnTheSelectedTabOnce() {
        let router = Router()
        router.selectedTab = .series
        BrowsePresentation.open(.series(id: "ser_1"), in: router)
        BrowsePresentation.open(.series(id: "ser_1"), in: router)
        #expect(router[path: .series] == [.series(id: "ser_1")])

        BrowsePresentation.open(.item(id: "li_1"), in: router)
        #expect(router[path: .series] == [.series(id: "ser_1"), .item(id: "li_1")])

        // Compact width shows the sections inside Library.
        router.selectedTab = .library
        BrowsePresentation.open(.author(id: "aut_1"), in: router)
        #expect(router[path: .library] == [.author(id: "aut_1")])
        #expect(router[path: .series] == [.series(id: "ser_1"), .item(id: "li_1")])

        BrowsePresentation.open(.author(id: "aut_1"), in: nil)
    }

    @Test func cancelledOrUnofferedCardActionsReportNothing() async {
        // HomePresentationTests cover the routes and the actions themselves (`ItemCardActions`).
        #expect(ItemCardActions.route(for: book("li_4", kind: .series)) == .item(id: "li_4"))
        let actions = RecordingItemActions()
        actions.error = CancellationError()
        #expect(await ItemCardActions.perform(.markFinished, on: book("li_1"), actions: actions, play: nil) == nil)
        let play = PlayItemAction { _, _, _ in throw CancellationError() }
        #expect(await ItemCardActions.perform(.play, on: book("li_1"), actions: actions, play: play) == nil)

        actions.error = Failure()
        for kind in [ItemActionKind.share, .addToPlaylist, .openDetails] {
            #expect(await ItemCardActions.perform(kind, on: book("li_1"), actions: actions, play: play) == nil)
            #expect(ItemCardActions.failureMessageKey(for: kind) == nil)
        }
        #expect(actions.calls.map { $0.0 } == [.markFinished])
    }

    @Test func onlyTheFrontmostScreenHasTheRefreshCommand() {
        let router = Router()
        let screens: [RefreshCommandPlacement] = [
            .root(.home), .root(.series), .root(.authors), .pushed(.series(id: "ser_1")),
            .pushed(.author(id: "aut_1")),
        ]
        let frontmost = { screens.filter { $0.isFrontmost(in: router, isVisible: true) } }
        #expect(frontmost() == [.root(.home)])
        // Home opened a series, then its author.
        router[path: .home] = [.series(id: "ser_1")]
        #expect(frontmost() == [.pushed(.series(id: "ser_1"))])
        router[path: .home].append(.author(id: "aut_1"))
        #expect(frontmost() == [.pushed(.author(id: "aut_1"))])
        router.selectedTab = .series
        #expect(frontmost() == [.root(.series)])
        // Compact width: the Library tab shows the Authors section as its root.
        router.selectedTab = .library
        router.librarySection = .authors
        #expect(frontmost() == [.root(.authors)])
        #expect(RefreshCommandPlacement.root(.home).isFrontmost(in: nil, isVisible: true))
        #expect(!RefreshCommandPlacement.root(.home).isFrontmost(in: nil, isVisible: false))

        // Copies of a placement: covered stack screens and hidden tabs have disappeared.
        let commands = { (screens: [(RefreshCommandPlacement, Bool)]) in
            screens.filter { $0.0.isFrontmost(in: router, isVisible: $0.1) }.count
        }
        let seriesA = RefreshCommandPlacement.pushed(.series(id: "ser_a"))
        router.librarySection = .series
        #expect(commands([(.root(.series), true), (.root(.series), false)]) == 1)  // Library section, Series tab
        router.selectedTab = .series
        router[path: .series] = [.series(id: "ser_a"), .author(id: "aut_1"), .series(id: "ser_a")]
        #expect(commands([(seriesA, false), (seriesA, true)]) == 1)  // Twice in one stack
        router.selectedTab = .home
        router[path: .home] = [.series(id: "ser_a")]
        #expect(commands([(seriesA, true), (seriesA, false)]) == 1)  // Home, hidden Series tab
    }

    /// View ▸ Refresh runs only the frontmost screen's action, never a hidden tab's that is still registered (macOS
    /// keeps hidden tabs appeared), and is disabled while that screen loads (#393).
    @Test func refreshCommandRunsOnlyTheFrontmostScreen() {
        let router = Router()
        let registry = RefreshCommandRegistry()
        var runs: [String] = []
        func register(_ name: String, _ placement: RefreshCommandPlacement, loading: Bool = false) -> UUID {
            let id = UUID()
            registry.register(id, .init(placement: placement, isDisabled: loading, perform: { runs.append(name) }))
            return id
        }
        func refresh() -> Bool? {
            let action = registry.frontmost(in: router)
            action?.perform()
            return action?.isDisabled
        }

        #expect(refresh() == nil)
        let home = register("home", .root(.home))
        _ = register("series tab", .root(.series))
        _ = register("authors tab", .root(.authors), loading: true)
        #expect(refresh() == false)
        #expect(runs == ["home"])

        // Home pushes a series: its screen is frontmost; Home is covered (and has disappeared).
        router[path: .home] = [.series(id: "ser_1")]
        registry.unregister(home)
        let series = register("series", .pushed(.series(id: "ser_1")), loading: true)
        #expect(refresh() == true)
        #expect(runs == ["home", "series"])
        // Loaded: enabled again.
        registry.register(series, .init(placement: .pushed(.series(id: "ser_1")), isDisabled: false, perform: {}))
        #expect(refresh() == false)

        // Another tab: its root, not the hidden Home stack's series.
        runs = []
        router.selectedTab = .series
        #expect(refresh() == false)
        router.selectedTab = .authors
        #expect(refresh() == true)
        #expect(runs == ["series tab", "authors tab"])

        // The pushed screen gone: nothing in Home.
        router.selectedTab = .home
        registry.unregister(series)
        #expect(refresh() == nil)
        #expect(runs == ["series tab", "authors tab"])
    }

    @Test func failedRefreshShowsAboveTheItemsAndAFailedPageAfterThem() async throws {
        #expect(BrowsePresentation.failurePlacement(failed: false, refreshFailed: false) == nil)
        #expect(BrowsePresentation.failurePlacement(failed: false, refreshFailed: true) == nil)
        #expect(BrowsePresentation.failurePlacement(failed: true, refreshFailed: true) == .top)
        #expect(BrowsePresentation.failurePlacement(failed: true, refreshFailed: false) == .footer)

        let client = FakeSeriesAuthorsClient()
        try await withStore(client) { store in
            let (key, services) = try keyAndServices(store)
            let list = SeriesPresentation.makeList(key: key, services: services)
            await list.loadNextPage()?.value
            client.fails.withLock { $0 = true }
            #expect(await BrowsePresentation.refresh(list))
            #expect(BrowseScreenState.resolve(list: list) == .loaded(failed: true))
            #expect(list.items.count == SampleLibrary.series.count)

            client.fails.withLock { $0 = false }
            #expect(await BrowsePresentation.refresh(list) == false)
            #expect(BrowseScreenState.resolve(list: list) == .loaded(failed: false))
        }
    }

    @Test func everyMessageKeyIsInTheCatalog() {
        let messages = [
            SeriesPresentation.listMessages, SeriesPresentation.detailMessages, AuthorsPresentation.listMessages,
            AuthorsPresentation.detailMessages,
        ]
        let actions: [ItemActionKind] = [.play, .markFinished, .markNotFinished, .hideFromContinueListening]
        let keys =
            messages.flatMap { [$0.failed, $0.empty, $0.notFound] }
            + actions.compactMap { ItemCardActions.failureMessageKey(for: $0) }
            + [AuthorsPresentation.booksFailedMessage, "ButtonRefresh", "LabelSeriesBookNumber"]
        for key in keys {
            #expect(L10n.string(key) != key, "\(key) isn't in the catalog")
        }
    }
}

@MainActor
@Suite struct SeriesPresentationTests {
    @Test func seriesListAsksForOnePageByName() async throws {
        let client = FakeSeriesAuthorsClient()
        try await withStore(client) { store in
            let (key, services) = try keyAndServices(store)
            let list = SeriesPresentation.makeList(key: key, services: services)
            await list.loadNextPage()?.value
            #expect(list.items.map(\.name) == SampleLibrary.series.map(\.name))
            let request = try #require(client.seriesRequests.withLock { $0.first })
            #expect(request.libraryID == "lib_a")
            #expect(
                request.query.queryItems == [
                    URLQueryItem(name: "sort", value: "name"), URLQueryItem(name: "desc", value: "0"),
                    URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "page", value: "0"),
                ])
        }
    }

    @Test func sequenceBadgeShowsTheSequence() {
        #expect(SeriesPresentation.sequenceBadge("1") == "#1")
        #expect(SeriesPresentation.sequenceBadge(" 2.5 ") == "#2.5")
        #expect(SeriesPresentation.sequenceBadge("") == nil)
        #expect(SeriesPresentation.sequenceBadge("  ") == nil)
        #expect(SeriesPresentation.sequenceBadge(nil) == nil)
    }

    @Test func cardsReadThisSeriesAndNumber() {
        let summary = ItemSummary(
            id: "li_2", itemID: "li_2", kind: .book, title: "The Gods of Mars", subtitle: "Edgar Rice Burroughs",
            seriesText: "Other Series #9", duration: 60, isExplicit: true, isAbridged: true)
        let card = SeriesPresentation.card(for: SeriesBook(summary: summary, sequence: " 2 "), in: "Barsoom")
        #expect(card.seriesText == L10n.string("LabelSeriesBookNumber", "Barsoom", "2"))
        #expect(card.seriesText == "Barsoom, #2")
        #expect(
            card
                == ItemSummary(
                    id: "li_2", itemID: "li_2", kind: .book, title: "The Gods of Mars",
                    subtitle: "Edgar Rice Burroughs", seriesText: "Barsoom, #2", duration: 60, isExplicit: true,
                    isAbridged: true))
        // Any sequence reads as the badge shows it.
        for sequence in ["Prequel", "2.5"] {
            let card = SeriesPresentation.card(for: SeriesBook(summary: summary, sequence: sequence), in: "Barsoom")
            #expect(card.seriesText == "Barsoom, #\(sequence)")
        }

        // A collapsed sub-series, or a book without a number, reads the series alone.
        let collapsed = ItemSummary(id: "ser_2", itemID: "li_3", seriesID: "ser_2", kind: .series, title: "Early")
        #expect(
            SeriesPresentation.card(for: SeriesBook(summary: collapsed, sequence: nil), in: "Barsoom").seriesText
                == "Barsoom")
        #expect(
            SeriesPresentation.card(for: SeriesBook(summary: summary, sequence: " "), in: "Barsoom").seriesText
                == "Barsoom")
    }

    @Test func booksKeepTheServersSequenceOrder() async throws {
        // The server sorts a series filter by sequence; the screen must not sort again.
        let books = [
            barsoom(SampleLibrary.godsOfMars, "2"), barsoom(SampleLibrary.princessOfMars, "1"),
            barsoom(SampleLibrary.warlordOfMars, "3"),
        ]
        let client = FakeSeriesAuthorsClient(books: books)
        try await withStore(client) { store in
            let (_, services) = try keyAndServices(store, entityID: "ser_barsoom")
            let model = SeriesDetailModel(
                seriesID: "ser_barsoom", libraryID: "lib_a", service: services, cache: store.progress)
            await model.loadIfNeeded()
            #expect(SeriesPresentation.state(of: model) == .loaded(failed: false))
            let badges = model.detail?.books.map { SeriesPresentation.sequenceBadge($0.sequence) }
            #expect(badges == ["#2", "#1", "#3"])
            let query = try #require(client.bookRequests.withLock { $0.first?.query })
            #expect(query.sort == nil)
            #expect(query.filter == .series(id: "ser_barsoom"))
        }
    }

    @Test func continueSeriesOpensTheFirstUnfinishedBook() async throws {
        try await withStore { store in
            let (_, services) = try keyAndServices(store, entityID: "ser_barsoom")
            let model = SeriesDetailModel(
                seriesID: "ser_barsoom", libraryID: "lib_a", service: services, cache: store.progress)
            await model.loadIfNeeded()
            store.progress.apply(
                MediaProgress(
                    id: "mp_1", libraryItemId: SampleLibrary.princessOfMars.id, progress: 1, isFinished: true))

            let next = try #require(model.continueBook)
            #expect(SeriesPresentation.continueRoute(for: next) == .item(id: SampleLibrary.godsOfMars.id))
            #expect(
                SeriesPresentation.continueAccessibilityLabel(for: next)
                    == "\(L10n.string("LabelContinueSeries")), The Gods of Mars")
        }
    }

    @Test func detailStatesFollowTheModel() async throws {
        let client = FakeSeriesAuthorsClient()
        try await withStore(client) { store in
            let (_, services) = try keyAndServices(store)
            let missing = SeriesDetailModel(
                seriesID: "ser_gone", libraryID: "lib_a", service: services, cache: store.progress)
            #expect(SeriesPresentation.state(of: missing) == .loading)
            await missing.loadIfNeeded()
            #expect(SeriesPresentation.state(of: missing) == .notFound)

            let series = SeriesDetailModel(
                seriesID: "ser_barsoom", libraryID: "lib_a", service: services, cache: store.progress)
            client.fails.withLock { $0 = true }
            await series.loadIfNeeded()
            #expect(SeriesPresentation.state(of: series) == .failed)
            client.fails.withLock { $0 = false }
            await series.loadIfNeeded()
            client.fails.withLock { $0 = true }
            await series.load()
            #expect(SeriesPresentation.state(of: series) == .loaded(failed: true))
        }
    }
}

@MainActor
@Suite struct AuthorsPresentationTests {
    @Test func authorBooksUseTheAuthorsFilterByTitle() async throws {
        let client = FakeSeriesAuthorsClient()
        try await withStore(client) { store in
            let (key, services) = try keyAndServices(store, entityID: "aut_burroughs")
            let model = AuthorsPresentation.makeDetail(authorID: "aut_burroughs", key: key, services: services)
            await model.loadIfNeeded()
            #expect(AuthorsPresentation.state(of: model) == .loaded(failed: false))
            #expect(BrowseScreenState.resolve(list: model.books) == .loaded(failed: false))

            let request = try #require(client.bookRequests.withLock { $0.first })
            #expect(request.libraryID == "lib_a")
            let filter = try #require(request.query.queryItems.first { $0.name == "filter" }?.value)
            #expect(filter == LibraryFilter.authors(id: "aut_burroughs").queryValue)
            #expect(filter.hasPrefix("authors."))
            #expect(request.query.sort == "media.metadata.title")
            #expect(!request.query.descending)
        }
    }

    @Test func missingAuthorIsNotFound() async throws {
        try await withStore { store in
            let (key, services) = try keyAndServices(store, entityID: "aut_gone")
            let model = AuthorsPresentation.makeDetail(authorID: "aut_gone", key: key, services: services)
            await model.loadIfNeeded()
            #expect(AuthorsPresentation.state(of: model) == .notFound)
        }
    }

    @Test func authorsListStates() async throws {
        let client = FakeSeriesAuthorsClient()
        try await withStore(client) { store in
            let (_, services) = try keyAndServices(store)
            let model = AuthorsModel(libraryID: "lib_a", service: services)
            #expect(AuthorsPresentation.state(of: model) == .loading)
            client.fails.withLock { $0 = true }
            await model.loadIfNeeded()
            #expect(AuthorsPresentation.state(of: model) == .failed)
            client.fails.withLock { $0 = false }
            await model.loadIfNeeded()
            #expect(AuthorsPresentation.state(of: model) == .loaded(failed: false))
            client.fails.withLock { $0 = true }
            await model.load()
            #expect(AuthorsPresentation.state(of: model) == .loaded(failed: true))
        }
    }

    @Test func failedRefreshShowsOnceAboveTheAuthorAndRetryRefreshes() async throws {
        let client = FakeSeriesAuthorsClient()
        try await withStore(client) { store in
            let (key, services) = try keyAndServices(store, entityID: "aut_burroughs")
            let model = AuthorsPresentation.makeDetail(authorID: "aut_burroughs", key: key, services: services)
            await model.loadIfNeeded()
            #expect(AuthorsPresentation.failurePlacement(of: model, refreshFailed: false) == nil)

            client.fails.withLock { $0 = true }
            let failed = await AuthorsPresentation.refresh(model)
            #expect(failed)
            // One row above the author, none after the books, which stay.
            #expect(AuthorsPresentation.failurePlacement(of: model, refreshFailed: failed) == .top)
            #expect(model.books.items.count == 3)

            // Retry refreshes the author and the books from their first page.
            client.fails.withLock { $0 = false }
            client.bookRequests.withLock { $0.removeAll() }
            #expect(await AuthorsPresentation.refresh(model) == false)
            let request = try #require(client.bookRequests.withLock { $0.last })
            #expect(request.query.queryItems.contains(URLQueryItem(name: "page", value: "0")))
            #expect(AuthorsPresentation.state(of: model) == .loaded(failed: false))

            // The books failing on their own (paging) show after them.
            client.fails.withLock { $0 = true }
            await model.books.refresh()?.value
            #expect(AuthorsPresentation.failurePlacement(of: model, refreshFailed: false) == .footer)
        }
    }

    @Test func bookCountPrefersTheLibrarysTotal() {
        let author = AuthorSummary(id: "aut_1", name: "Author", bookCount: 3)
        #expect(AuthorsPresentation.bookCount(total: 5, author: author) == L10n.plural("SharedBookCount", count: 5))
        #expect(AuthorsPresentation.bookCount(total: nil, author: author) == L10n.plural("SharedBookCount", count: 3))
        #expect(AuthorsPresentation.bookCount(total: nil, author: AuthorSummary(id: "aut_2", name: "Author")) == nil)
        #expect(AuthorsPresentation.bookCount(total: 0, author: author)?.contains("0") == true)
    }
}

/// Records the progress actions a screen sends, and throws `error` when set.
@MainActor
private final class RecordingItemActions: ItemActionPerforming {
    var calls: [(ItemActionKind, ItemActionTarget)] = []
    var error: (any Error)?

    func markFinished(_ target: ItemActionTarget) async throws { try record(.markFinished, target) }
    func markNotFinished(_ target: ItemActionTarget) async throws { try record(.markNotFinished, target) }
    func hideFromContinueListening(_ target: ItemActionTarget) async throws {
        try record(.hideFromContinueListening, target)
    }
    func discardProgress(_ target: ItemActionTarget) async throws {
        Issue.record("The series and author screens never discard progress")
    }

    private func record(_ kind: ItemActionKind, _ target: ItemActionTarget) throws {
        calls.append((kind, target))
        if let error { throw error }
    }
}
