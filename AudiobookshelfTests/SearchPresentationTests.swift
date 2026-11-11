import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import Foundation
import Testing

@testable import Audiobookshelf

/// Answers every search with no results.
private struct EmptySearchService: SearchService {
    func searchLibrary(id: String, query: String, limit: Int?) async throws -> LibrarySearchResults {
        LibrarySearchResults()
    }
}

/// A library client that also searches, as `APIClient` does: finds Emma in every library.
private struct SearchingLibraryService: LibraryService, SearchService {
    struct Failure: Error {}

    func libraries() async throws -> [Library] { [] }
    func library(id: String) async throws -> LibraryWithFilterData { throw Failure() }
    func personalizedShelves(libraryID: String) async throws -> [Shelf] { [] }
    func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> {
        throw Failure()
    }
    func searchLibrary(id: String, query: String, limit: Int?) async throws -> LibrarySearchResults {
        LibrarySearchResults(books: [SampleLibrary.emma])
    }
}

private let english = Locale(identifier: "en")

private let account = LibraryConnectionKey(
    connectionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA") ?? UUID(), userID: "user-1")

/// Every section filled, as a book library and a podcast library would between them.
private let allResults = SearchResultGroups(
    LibrarySearchResults(
        books: [SampleLibrary.emma], podcasts: [SampleLibrary.podcast], episodes: [SampleLibrary.episodeItems[0]],
        series: [
            LibrarySearchResults.SeriesMatch(
                series: SampleLibrary.series[0], books: SampleLibrary.series[0].books ?? [])
        ],
        authors: [SampleLibrary.authors[0]],
        narrators: [LibrarySearchResults.NameMatch(name: "Stephen Fry", count: 3)],
        tags: [LibrarySearchResults.NameMatch(name: "Classics", count: 12)]))

@MainActor
@Suite struct SearchPresentationTests {
    private func row(_ kind: SearchSectionKind) throws -> SearchResultRow {
        try #require(allResults.rows(kind).first)
    }

    @Test func sectionsUseTheLegacyHeadersInTheLegacyOrder() {
        #expect(
            allResults.sections.map { SearchPresentation.titleKey(of: $0.kind) } == [
                "LabelBooks", "LabelPodcasts", "HeaderEpisodes", "LabelSeries", "LabelAuthors", "LabelNarrators",
                "LabelTags",
            ])
    }

    @Test(arguments: SearchSectionKind.allCases)
    func everySectionHasLocalizedHeaderAndKind(_ kind: SearchSectionKind) {
        for key in [SearchPresentation.titleKey(of: kind), SearchPresentation.kindKey(of: kind)] {
            #expect(L10n.string(key, locale: english) != key, "\(key) is missing from the catalog")
        }
    }

    @Test func rowsShowTitleAndSecondLine() throws {
        #expect(SearchPresentation.title(of: try row(.books)) == "Emma")
        #expect(SearchPresentation.subtitle(of: try row(.books)) == "Jane Austen")
        #expect(SearchPresentation.title(of: try row(.episodes)) == SampleLibrary.episodes[0].title)
        #expect(SearchPresentation.subtitle(of: try row(.episodes)) == "Classic Tales")
        #expect(SearchPresentation.title(of: try row(.series)) == "Barsoom")
        #expect(SearchPresentation.subtitle(of: try row(.series), locale: english) == "3 books")
        #expect(SearchPresentation.title(of: try row(.narrators)) == "Stephen Fry")
        #expect(SearchPresentation.subtitle(of: try row(.narrators)) == nil)
        #expect(SearchPresentation.subtitle(of: try row(.tags)) == nil)
    }

    @Test func oneBookIsSingular() {
        #expect(SearchPresentation.bookCount(1, locale: english) == "1 book")
        #expect(SearchPresentation.bookCount(2, locale: english) == "2 books")
        #expect(SearchPresentation.bookCount(0, locale: english) == "0 books")
    }

    @Test func voiceOverSpeaksTitleAuthorAndKind() throws {
        #expect(
            SearchPresentation.accessibilityLabel(of: try row(.books), in: .books, locale: english)
                == "Emma, Jane Austen, Book")
        #expect(
            SearchPresentation.accessibilityLabel(of: try row(.podcasts), in: .podcasts, locale: english)
                == "Classic Tales, Public Domain Players, Podcast")
        #expect(
            SearchPresentation.accessibilityLabel(of: try row(.series), in: .series, locale: english)
                == "Barsoom, 3 books, Series")
        #expect(
            SearchPresentation.accessibilityLabel(of: try row(.narrators), in: .narrators, locale: english)
                == "Stephen Fry, Narrator")
        #expect(
            SearchPresentation.accessibilityLabel(of: try row(.tags), in: .tags, locale: english) == "Classics, Tag")
    }

    @Test func narratorsAndTagsOpenTheFilteredLibraryOnTheSearchStack() throws {
        let router = Router()
        router[path: .home] = [.stats]
        SearchPresentation.open(try row(.narrators).route, in: router)
        #expect(router[path: .search] == [.libraryFilter(kind: .narrators, value: "Stephen Fry")])

        router[path: .search] = []
        SearchPresentation.open(try row(.tags).route, in: router)
        #expect(router[path: .search] == [.libraryFilter(kind: .tags, value: "Classics")])
        #expect(router[path: .home] == [.stats])
        #expect(router[path: .library].isEmpty)
    }

    @Test func itemsEpisodesSeriesAndAuthorsOpenTheirScreens() throws {
        let router = Router()
        for kind in [SearchSectionKind.books, .podcasts, .episodes, .series, .authors] {
            SearchPresentation.open(try row(kind).route, in: router)
        }
        let author = SampleLibrary.authors[0].id
        #expect(
            router[path: .search] == [
                .item(id: "li_emma"), .item(id: "li_podcast"),
                .episode(itemID: "li_podcast", episodeID: SampleLibrary.episodes[0].id), .series(id: "ser_barsoom"),
                .author(id: author),
            ])
    }

    @Test func aDoubleTapPushesOnce() throws {
        let router = Router()
        SearchPresentation.open(try row(.books).route, in: router)
        SearchPresentation.open(try row(.books).route, in: router)
        #expect(router[path: .search] == [.item(id: "li_emma")])
        SearchPresentation.open(try row(.books).route, in: nil)
    }
}

@MainActor
@Suite struct SearchScreenStateTests {
    private typealias Inputs = SearchScreenState.Inputs

    @Test func withoutAnAccountOrLibraryThereIsNothingToSearch() {
        #expect(SearchScreenState.placeholder(canSearch: false, libraryID: "lib") == .signedOut)
        #expect(SearchScreenState.placeholder(canSearch: true, libraryID: nil) == .noLibrary)
        #expect(SearchScreenState.placeholder(canSearch: true, libraryID: "lib") == .loading)
    }

    @Test func aBlankQueryShowsTheRecentSearches() {
        #expect(SearchScreenState.resolve(Inputs()) == .idle)
        #expect(SearchScreenState.resolve(Inputs(query: "  ", hasError: true, hasResults: true)) == .idle)
    }

    @Test func theSpinnerShowsOnlyWhileARequestRuns() {
        #expect(SearchScreenState.resolve(Inputs(query: "dune", isSearching: true)) == .searching)
        #expect(SearchScreenState.resolve(Inputs(query: " dune ", searchedQuery: "dune")) == .noResults)
    }

    @Test func duringTheDebounceTheScreenKeepsWhatItShowed() {
        // Nothing searched yet: the recent searches stay.
        #expect(SearchScreenState.resolve(Inputs(query: "dune")) == .idle)
        // An earlier search found nothing: its message stays.
        #expect(SearchScreenState.resolve(Inputs(query: "dune", searchedQuery: "dun")) == .noResults)
        // An earlier search found something: its results stay, without a spinner.
        #expect(
            SearchScreenState.resolve(Inputs(query: "dune", searchedQuery: "dun", hasResults: true))
                == .results(isSearching: false, failed: false))
    }

    @Test func aFailureShowsRetryOrKeepsTheResults() {
        #expect(SearchScreenState.resolve(Inputs(query: "dune", hasError: true)) == .failed)
        #expect(SearchScreenState.resolve(Inputs(query: "dune", isSearching: true, hasError: true)) == .searching)
        #expect(
            SearchScreenState.resolve(Inputs(query: "dune", searchedQuery: "dun", hasError: true, hasResults: true))
                == .results(isSearching: false, failed: true))
        #expect(
            SearchScreenState.resolve(Inputs(query: "dune", searchedQuery: "dun", isSearching: true, hasResults: true))
                == .results(isSearching: true, failed: false))
    }

    @Test func aTypedQueryWaitingForTheDebounceKeepsTheRecentSearches() {
        let model = SearchModel(service: EmptySearchService(), libraryID: "lib", debounce: .seconds(60))
        #expect(SearchScreenState.resolve(model) == .idle)
        model.setQuery("dune")
        #expect(SearchScreenState.resolve(model) == .idle)
    }
}

@MainActor
@Suite struct SearchRecentsStoreTests {
    private func withStore(_ body: (SearchRecentsStore, AppSettings) throws -> Void) throws {
        let suiteName = "SearchRecentsStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        try body(SearchRecentsStore(settings: settings), settings)
    }

    @Test func recentSearchesAreKeptPerAccountAndLibrary() throws {
        try withStore { store, _ in
            let other = LibraryConnectionKey(connectionID: account.connectionID, userID: "user-2")
            store.setRecentSearches(["Dune", "Emma \"Austen\""], connectionKey: account, libraryID: "books")
            store.setRecentSearches(["Serial"], connectionKey: account, libraryID: "podcasts")
            #expect(store.recentSearches(connectionKey: account, libraryID: "books") == ["Dune", "Emma \"Austen\""])
            #expect(store.recentSearches(connectionKey: account, libraryID: "podcasts") == ["Serial"])
            #expect(store.recentSearches(connectionKey: other, libraryID: "books").isEmpty)
        }
    }

    @Test func clearingRemovesTheLibrarysEntryAndResetAllRemovesEverything() throws {
        try withStore { store, settings in
            store.setRecentSearches(["Dune"], connectionKey: account, libraryID: "books")
            store.setRecentSearches(["Serial"], connectionKey: account, libraryID: "podcasts")
            store.setRecentSearches([], connectionKey: account, libraryID: "books")
            #expect(settings.recentSearches.count == 1)

            settings.resetAll()
            #expect(store.recentSearches(connectionKey: account, libraryID: "podcasts").isEmpty)
        }
    }

    @Test func unreadableJSONIsNoRecentSearches() throws {
        try withStore { store, settings in
            settings.setRecentSearchesJSON(
                "{", serverID: account.serverID, userID: account.userID, libraryID: "books")
            #expect(store.recentSearches(connectionKey: account, libraryID: "books").isEmpty)
        }
    }

    @Test func theModelSavesAndRestoresItsLibrarysRecentSearches() throws {
        try withStore { store, _ in
            let model = SearchModel(
                service: EmptySearchService(), libraryID: "books",
                persistRecents: store.persist(connectionKey: account, libraryID: "books"))
            model.setQuery("Dune")
            model.submit()
            model.setQuery("Emma")
            model.submit()
            #expect(store.recentSearches(connectionKey: account, libraryID: "books") == ["Emma", "Dune"])

            let restored = SearchModel(
                service: EmptySearchService(), libraryID: "books",
                recentSearches: store.recentSearches(connectionKey: account, libraryID: "books"))
            #expect(restored.recentSearches == ["Emma", "Dune"])

            model.clearRecentSearches()
            #expect(store.recentSearches(connectionKey: account, libraryID: "books").isEmpty)
        }
    }
}

/// Stands in for a `LibraryStore` in session keys.
private final class StoreToken {}

@MainActor
@Suite struct SearchSessionTests {
    private let store = StoreToken()

    private func key(_ libraryID: String, account: LibraryConnectionKey = account, store: StoreToken? = nil)
        -> SearchSession.Key
    {
        SearchSession.Key(
            store: ObjectIdentifier(store ?? self.store), connectionKey: account, libraryID: libraryID)
    }

    private func makeModel(_ key: SearchSession.Key) -> SearchModel? {
        SearchModel(service: EmptySearchService(), libraryID: key.libraryID, debounce: .seconds(60))
    }

    @Test func aLinkArrivingWithoutAModelWaitsInTheRouter() throws {
        let router = Router()
        router.pendingSearchQuery = "dune"
        var session = SearchSession()
        session.runPendingQuery(from: router)
        #expect(router.pendingSearchQuery == "dune")

        session.adopt(key("books"), makeModel: makeModel)
        session.runPendingQuery(from: router)
        let model = try #require(session.model)
        #expect(model.query == "dune")
        #expect(model.recentSearches == ["dune"])
        #expect(router.pendingSearchQuery == nil)
    }

    @Test func theQuerySurvivesALibraryOnlyRebuild() async throws {
        var session = SearchSession()
        session.adopt(key("books"), makeModel: makeModel)
        let books = try #require(session.model)
        books.setQuery("dune")

        let replaced = session.adopt(key("podcasts"), makeModel: makeModel)
        #expect(replaced)
        let podcasts = try #require(session.model)
        #expect(podcasts !== books)
        #expect(podcasts.libraryID == "podcasts")
        #expect(podcasts.query == "dune")
        // Searched at once, not after the debounce, and not recorded: the user didn't submit it.
        for _ in 0..<1_000 where podcasts.searchedQuery == nil { await Task.yield() }
        #expect(podcasts.searchedQuery == "dune")
        #expect(podcasts.recentSearches.isEmpty)
    }

    @Test func aDeepLinkedQueryInTheOldLibrarySurvivesTheSwitch() throws {
        let router = Router()
        var session = SearchSession()
        session.adopt(key("books"), makeModel: makeModel)
        router.pendingSearchQuery = "serial"
        session.runPendingQuery(from: router)

        session.adopt(key("podcasts"), makeModel: makeModel)
        #expect(try #require(session.model).query == "serial")
    }

    @Test func anUnchangedKeyKeepsTheModel() throws {
        var session = SearchSession()
        session.adopt(key("books"), makeModel: makeModel)
        let model = try #require(session.model)
        let replaced = session.adopt(key("books"), makeModel: makeModel)
        #expect(!replaced)
        #expect(session.model === model)
    }

    @Test func anotherAccountOrStoreStartsEmpty() throws {
        var session = SearchSession()
        session.adopt(key("books"), makeModel: makeModel)
        try #require(session.model).setQuery("dune")
        let otherAccount = LibraryConnectionKey(connectionID: account.connectionID, userID: "user-2")
        session.adopt(key("books", account: otherAccount), makeModel: makeModel)
        #expect(try #require(session.model).query.isEmpty)

        try #require(session.model).setQuery("dune")
        let otherStore = StoreToken()
        session.adopt(key("books", account: otherAccount, store: otherStore), makeModel: makeModel)
        #expect(try #require(session.model).query.isEmpty)
    }

    @Test func withoutAServiceTheSessionIsUnavailable() {
        var session = SearchSession()
        #expect(!session.isUnavailable)
        session.adopt(key("books")) { _ in nil }
        #expect(session.model == nil)
        #expect(session.isUnavailable)
        session.adopt(nil, makeModel: makeModel)
        #expect(!session.isUnavailable)
    }
}

/// A window's search session switching libraries after the history was cleared elsewhere.
@MainActor
@Suite struct SearchLibraryRoundTripTests {
    private func withSession(
        _ body: (
            _ session: inout SearchSession, _ keys: (books: SearchSession.Key, podcasts: SearchSession.Key),
            _ store: LibraryStore, _ settings: AppSettings
        ) async throws -> Void
    ) async throws {
        let suiteName = "SearchLibraryRoundTripTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let store = LibraryStore(settings: settings)
        await store.connect(client: SearchingLibraryService(), connectionKey: account)
        func key(_ libraryID: String) -> SearchSession.Key {
            SearchSession.Key(store: ObjectIdentifier(store), connectionKey: account, libraryID: libraryID)
        }
        var session = SearchSession()
        session.adopt(key("books")) { SearchSession.makeModel(for: $0, store: store, settings: settings) }
        let model = try #require(session.model)
        model.setQuery("dune")
        model.submit()
        #expect(model.recentSearches == ["dune"])
        try await body(&session, (key("books"), key("podcasts")), store, settings)
    }

    private func recents(_ settings: AppSettings, _ libraryID: String) -> [String] {
        SearchRecentsStore(settings: settings).recentSearches(connectionKey: account, libraryID: libraryID)
    }

    /// Books → podcasts → books, as the window's library picker does.
    private func roundTrip(
        _ session: inout SearchSession, _ keys: (books: SearchSession.Key, podcasts: SearchSession.Key),
        store: LibraryStore, settings: AppSettings
    ) async throws {
        for key in [keys.podcasts, keys.books] {
            session.adopt(key) { SearchSession.makeModel(for: $0, store: store, settings: settings) }
            let model = try #require(session.model)
            #expect(model.query == "dune")
            for _ in 0..<1_000 where model.searchedQuery == nil { await Task.yield() }
            #expect(model.searchedQuery == "dune")
        }
    }

    @Test func aClearInAnotherWindowSurvivesALibraryRoundTrip() async throws {
        try await withSession { session, keys, store, settings in
            let otherWindow = try #require(SearchSession.makeModel(for: keys.books, store: store, settings: settings))
            otherWindow.clearRecentSearches()

            try await roundTrip(&session, keys, store: store, settings: settings)
            #expect(recents(settings, "books").isEmpty)
            #expect(recents(settings, "podcasts").isEmpty)
            #expect(try #require(session.model).recentSearches.isEmpty)
        }
    }

    @Test func resetAllSurvivesALibraryRoundTrip() async throws {
        try await withSession { session, keys, store, settings in
            settings.resetAll()

            try await roundTrip(&session, keys, store: store, settings: settings)
            #expect(settings.recentSearches.isEmpty)
        }
    }

    @Test func anExplicitSubmitAfterTheRoundTripStillRecords() async throws {
        try await withSession { session, keys, store, settings in
            settings.resetAll()
            try await roundTrip(&session, keys, store: store, settings: settings)

            try #require(session.model).submit()
            #expect(recents(settings, "books") == ["dune"])
        }
    }
}

/// Two windows' models of one account and library, made as the Search tab makes them.
@MainActor
@Suite struct SearchSharedRecentsTests {
    private func withTwoModels(
        _ body: (_ first: SearchModel, _ second: SearchModel, _ settings: AppSettings) throws -> Void
    ) async throws {
        let suiteName = "SearchSharedRecentsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let store = LibraryStore(settings: settings)
        await store.connect(client: SearchingLibraryService(), connectionKey: account)
        let key = SearchSession.Key(store: ObjectIdentifier(store), connectionKey: account, libraryID: "books")
        let first = try #require(SearchSession.makeModel(for: key, store: store, settings: settings))
        let second = try #require(SearchSession.makeModel(for: key, store: store, settings: settings))
        // Both windows searched before, so each has seen the old terms.
        for (model, query) in [(first, "Dune"), (second, "Emma")] {
            model.setQuery(query)
            model.submit()
        }
        #expect(first.recentSearches == ["Emma", "Dune"])
        #expect(second.recentSearches == ["Emma", "Dune"])
        try body(first, second, settings)
    }

    private func stored(_ settings: AppSettings) -> [String] {
        SearchRecentsStore(settings: settings).recentSearches(connectionKey: account, libraryID: "books")
    }

    @Test func clearingInOneWindowIsNotUndoneByAnotherWindowsSearch() async throws {
        try await withTwoModels { first, second, settings in
            first.clearRecentSearches()
            #expect(second.recentSearches.isEmpty)

            second.setQuery("Serial")
            second.submit()
            #expect(stored(settings) == ["Serial"])
            #expect(first.recentSearches == ["Serial"])
            #expect(second.recentSearches == ["Serial"])
        }
    }

    @Test func resetAllIsNotUndoneByALiveModelsSearch() async throws {
        try await withTwoModels { first, second, settings in
            settings.resetAll()
            #expect(first.recentSearches.isEmpty)
            #expect(second.recentSearches.isEmpty)

            second.setQuery("Serial")
            second.submit()
            #expect(stored(settings) == ["Serial"])
            #expect(first.recentSearches == ["Serial"])
        }
    }
}

@MainActor
@Suite struct SearchSessionModelTests {
    @Test func theModelSearchesWithTheStoresServicesForItsAccount() async throws {
        let suiteName = "SearchSessionModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let store = LibraryStore(settings: settings)
        let token = ObjectIdentifier(store)
        let key = SearchSession.Key(store: token, connectionKey: account, libraryID: "books")
        #expect(SearchSession.makeModel(for: key, store: store, settings: settings) == nil)

        await store.connect(client: SearchingLibraryService(), connectionKey: account)
        let otherAccount = LibraryConnectionKey(connectionID: account.connectionID, userID: "user-2")
        let otherKey = SearchSession.Key(store: token, connectionKey: otherAccount, libraryID: "books")
        #expect(SearchSession.makeModel(for: otherKey, store: store, settings: settings) == nil)

        SearchRecentsStore(settings: settings).setRecentSearches(["Dune"], connectionKey: account, libraryID: "books")
        let model = try #require(SearchSession.makeModel(for: key, store: store, settings: settings))
        #expect(model.recentSearches == ["Dune"])
        model.setQuery("emma")
        model.submit()
        while model.isSearching || model.searchedQuery == nil { await Task.yield() }
        #expect(model.results.rows(.books).count == 1)
    }
}
