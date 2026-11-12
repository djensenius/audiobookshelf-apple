import ABSAPI
import ABSAppModel
import ABSCore
import Foundation
import Testing

@testable import Audiobookshelf

/// Records the progress actions Home sends, and fails them on request.
@MainActor
private final class RecordingItemActions: ItemActionPerforming {
    struct Failure: Error {}

    var calls: [(ItemActionKind, ItemActionTarget)] = []
    var fails = false

    func markFinished(_ target: ItemActionTarget) async throws { try record(.markFinished, target) }
    func markNotFinished(_ target: ItemActionTarget) async throws { try record(.markNotFinished, target) }
    func hideFromContinueListening(_ target: ItemActionTarget) async throws {
        try record(.hideFromContinueListening, target)
    }
    func discardProgress(_ target: ItemActionTarget) async throws {
        Issue.record("Home never discards progress")
    }

    private func record(_ kind: ItemActionKind, _ target: ItemActionTarget) throws {
        calls.append((kind, target))
        if fails { throw Failure() }
    }
}

/// The items a test's player was asked to play.
@MainActor
private final class PlayedItems {
    var items: [(String, String?)] = []
}

/// Serves shelves (or fails) per library; the libraries list succeeds unless `failsLibraries`.
private struct FakeLibraryService: LibraryService {
    struct Failure: Error {}

    var failsLibraries = false
    var failingShelves: Set<String> = []

    func libraries() async throws -> [Library] {
        if failsLibraries { throw Failure() }
        return []
    }

    func library(id: String) async throws -> LibraryWithFilterData { throw Failure() }

    func personalizedShelves(libraryID: String) async throws -> [Shelf] {
        if failingShelves.contains(libraryID) { throw Failure() }
        return SampleLibrary.shelves
    }

    func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> { throw Failure() }
}

private let account = LibraryConnectionKey(
    connectionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA") ?? UUID(), userID: "user-1")

@MainActor
@Suite struct HomeScreenStateTests {
    private typealias Inputs = HomeScreenState.Inputs

    /// Settings in a throwaway defaults suite, so a test never touches the app's.
    private func withStore(
        _ service: FakeLibraryService, _ body: (LibraryStore) async throws -> Void
    ) async throws {
        let suiteName = "HomeScreenStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LibraryStore(settings: AppSettings(defaults: defaults))
        await store.connect(client: service, connectionKey: account)
        try await body(store)
    }

    @Test func withoutAStoreOrAccountHomeIsSignedOut() {
        #expect(HomeScreenState.resolve(store: nil, model: nil, libraryID: "lib", sections: []) == .signedOut)
        #expect(HomeScreenState.resolve(Inputs(isSignedIn: false, hasLoaded: true, isEmpty: false)) == .signedOut)
    }

    @Test func aClearedStoreIsSignedOutNotLoading() async throws {
        try await withStore(FakeLibraryService()) { store in
            let model = HomeModel(store: store, libraryID: "lib")
            await model.load()
            store.clear()
            #expect(HomeScreenState.resolve(store: store, model: model, libraryID: "lib", sections: []) == .signedOut)
        }
    }

    @Test func withoutALibraryHomeWaitsForTheLibraries() {
        #expect(HomeScreenState.resolve(Inputs(librariesLoaded: false, libraryID: nil)) == .loading)
        #expect(
            HomeScreenState.resolve(Inputs(librariesLoaded: false, librariesLoading: true, libraryID: nil))
                == .loading)
        #expect(
            HomeScreenState.resolve(
                Inputs(librariesLoaded: false, librariesLoading: true, librariesFailed: true, libraryID: nil))
                == .loading)
        #expect(HomeScreenState.resolve(Inputs(librariesLoaded: true, libraryID: nil)) == .empty)
    }

    @Test func aFailedLibrariesRequestOffersRetry() async throws {
        try await withStore(FakeLibraryService(failsLibraries: true)) { store in
            let model = HomeModel(store: store)
            #expect(!store.hasLoaded && store.error != nil)
            #expect(
                HomeScreenState.resolve(store: store, model: model, libraryID: nil, sections: []) == .librariesFailed)
        }
    }

    @Test func firstLoadShowsLoadingThenItsError() {
        #expect(HomeScreenState.resolve(Inputs()) == .loading)
        #expect(HomeScreenState.resolve(Inputs(isLoading: true)) == .loading)
        #expect(HomeScreenState.resolve(Inputs(isLoading: true, hasError: true)) == .loading)
        #expect(HomeScreenState.resolve(Inputs(hasError: true)) == .failed)
    }

    @Test func loadedShelvesStayWhenAReloadFails() {
        #expect(HomeScreenState.resolve(Inputs(hasLoaded: true, isEmpty: false)) == .shelves(refreshFailed: false))
        #expect(
            HomeScreenState.resolve(Inputs(hasLoaded: true, hasError: true, isEmpty: false))
                == .shelves(refreshFailed: true))
    }

    @Test func loadedWithoutSectionsIsEmptyUnlessTheReloadFailed() {
        #expect(HomeScreenState.resolve(Inputs(hasLoaded: true)) == .empty)
        #expect(HomeScreenState.resolve(Inputs(hasLoaded: true, hasError: true)) == .failed)
    }

    @Test func aLibrarySwitchHidesTheOldShelvesUntilTheModelAdoptsIt() async throws {
        try await withStore(FakeLibraryService()) { store in
            let model = HomeModel(store: store, libraryID: "a")
            await model.load()
            let sections = model.sections
            #expect(!sections.isEmpty)
            #expect(
                HomeScreenState.resolve(store: store, model: model, libraryID: "a", sections: sections)
                    == .shelves(refreshFailed: false))

            // The router moved to "b"; the view's task hasn't run yet.
            #expect(HomeScreenState.resolve(store: store, model: model, libraryID: "b", sections: sections) == .loading)
        }
    }

    @Test func theOldLibrarysErrorDoesNotFailTheNewOne() async throws {
        try await withStore(FakeLibraryService(failingShelves: ["a"])) { store in
            let model = HomeModel(store: store, libraryID: "a")
            await model.load()
            #expect(model.error != nil)
            #expect(HomeScreenState.resolve(store: store, model: model, libraryID: "a", sections: []) == .failed)
            #expect(HomeScreenState.resolve(store: store, model: model, libraryID: "b", sections: []) == .loading)
        }
    }
}

@Suite struct HomeRefreshScheduleTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func loadsWhatIsntLoadedYet() {
        let schedule = HomeRefreshSchedule()
        #expect(schedule.request(libraryID: "a", hasLoaded: false, now: start) == .load)
        #expect(schedule.request(libraryID: "a", hasLoaded: false, now: start, force: true) == .load)
    }

    @Test func refreshesOnlyStaleShelvesUnlessForced() {
        var schedule = HomeRefreshSchedule()
        schedule.markLoaded(libraryID: "a", at: start)
        let fresh = start.addingTimeInterval(HomeRefreshSchedule.maxAge - 1)
        let stale = start.addingTimeInterval(HomeRefreshSchedule.maxAge)

        #expect(schedule.request(libraryID: "a", hasLoaded: true, now: fresh) == nil)
        #expect(schedule.request(libraryID: "a", hasLoaded: true, now: fresh, force: true) == .refresh)
        #expect(schedule.request(libraryID: "a", hasLoaded: true, now: stale) == .refresh)
    }

    @Test func shelvesOfAnotherLibraryOrNeverMarkedAreStale() {
        var schedule = HomeRefreshSchedule()
        #expect(schedule.request(libraryID: "a", hasLoaded: true, now: start) == .refresh)
        schedule.markLoaded(libraryID: "a", at: start)
        #expect(schedule.request(libraryID: "b", hasLoaded: true, now: start) == .refresh)
    }

    private let loaded = HomeRefreshSchedule.ModelState(
        libraryID: "a", hasLoaded: true, isLoading: false, hasError: false)

    @Test func aCompletedRefreshMakesTheShelvesFresh() {
        var schedule = HomeRefreshSchedule()
        schedule.markLoaded(libraryID: "a", at: start)
        let later = start.addingTimeInterval(HomeRefreshSchedule.maxAge)

        let recorded = schedule.recordCompletion(of: "a", model: loaded, isCancelled: false, at: later)
        #expect(recorded)
        #expect(schedule.request(libraryID: "a", hasLoaded: true, now: later.addingTimeInterval(1)) == nil)
    }

    /// Home disappeared during a stale refresh: the old shelves are still there without an error,
    /// but they aren't new, so the next appear still refreshes.
    @Test func aCancelledRefreshLeavesTheShelvesStale() {
        var schedule = HomeRefreshSchedule()
        schedule.markLoaded(libraryID: "a", at: start)
        let later = start.addingTimeInterval(HomeRefreshSchedule.maxAge)

        let recorded = schedule.recordCompletion(of: "a", model: loaded, isCancelled: true, at: later)
        #expect(!recorded)
        #expect(schedule.request(libraryID: "a", hasLoaded: true, now: later.addingTimeInterval(1)) == .refresh)
    }

    @Test func failedSupersededOrSwitchedRequestsAreNotRecorded() {
        var schedule = HomeRefreshSchedule()
        var failed = loaded
        failed.hasError = true
        var running = loaded
        running.isLoading = true
        var switched = loaded
        switched.libraryID = "b"
        var notLoaded = loaded
        notLoaded.hasLoaded = false

        for state in [failed, running, switched, notLoaded] {
            let recorded = schedule.recordCompletion(of: "a", model: state, isCancelled: false, at: start)
            #expect(!recorded)
        }
        #expect(schedule.request(libraryID: "a", hasLoaded: true, now: start) == .refresh)
    }
}

@MainActor
@Suite struct HomePresentationTests {
    private let sections = HomeSection.sections(from: SampleLibrary.shelves) { _, _ in nil }

    private func section(_ id: String) throws -> HomeSection {
        try #require(sections.first { $0.id == id })
    }

    @Test func titlesUseTheCatalogAndFallBackToTheServerLabel() throws {
        let english = Locale(identifier: "en")
        #expect(HomePresentation.title(of: try section("continue-listening"), locale: english) == "Continue Listening")
        // No key: the server's label.
        #expect(HomePresentation.title(of: try section("recent-series"), locale: english) == "Recent Series")
        let unknown = HomeSection(
            id: "x", titleKey: "LabelNoSuchShelfKey", label: "Server Label", kind: .book,
            entries: try section("continue-listening").entries)
        #expect(HomePresentation.title(of: unknown, locale: english) == "Server Label")
    }

    @Test func everySampleSectionMapsToItsCards() throws {
        #expect(sections.map(\.kind) == [.book, .episode, .book, .series, .authors])
        for section in sections {
            for entry in section.entries {
                switch (section.kind, entry) {
                case (.book, .item), (.podcast, .item), (.episode, .item), (.series, .series), (.authors, .author):
                    break
                default:
                    Issue.record("\(section.id) has a \(entry) entry")
                }
            }
        }
    }

    @Test func entriesOpenTheirRoutes() throws {
        let book = ItemSummary(item: SampleLibrary.frankenstein)
        let episode = ItemSummary(item: SampleLibrary.episodeItems[0])
        let collapsed = ItemSummary(
            id: "series-ser_1", itemID: "li_first", seriesID: "ser_1", kind: .series, title: "Series")
        let podcast = ItemSummary(id: "li_pod", itemID: "li_pod", kind: .podcast, title: "Podcast")
        let series = SeriesSummary(series: SampleLibrary.series[0])
        let author = AuthorSummary(author: SampleLibrary.authors[0])

        #expect(HomePresentation.route(for: .item(book)) == .item(id: book.itemID))
        #expect(
            HomePresentation.route(for: .item(episode))
                == .episode(itemID: episode.itemID, episodeID: try #require(episode.episodeID)))
        #expect(HomePresentation.route(for: .item(collapsed)) == .series(id: "ser_1"))
        #expect(HomePresentation.route(for: .item(podcast)) == .item(id: "li_pod"))
        #expect(HomePresentation.route(for: .series(series)) == .series(id: series.id))
        #expect(HomePresentation.route(for: .author(author)) == .author(id: author.id))
    }

    @Test func playIsOfferedOnlyWithAPlayer() {
        let book = ItemSummary(item: SampleLibrary.frankenstein)
        let progress = ItemProgress(fraction: 0.4)
        let withPlayer = ItemAction.available(
            for: book, progress: progress, context: ItemCardActions.actionContext(canPlay: true)
        )
        .map(\.kind)
        let withoutPlayer = ItemAction.available(
            for: book, progress: progress, context: ItemCardActions.actionContext(canPlay: false)
        )
        .map(\.kind)

        #expect(withPlayer == [.play, .markFinished, .hideFromContinueListening, .openDetails])
        #expect(withoutPlayer == [.markFinished, .hideFromContinueListening, .openDetails])
    }

    @Test func openInNewWindowIsOfferedOnlyWithWindows() async {
        let book = ItemSummary(item: SampleLibrary.frankenstein)
        let withWindows = ItemCardActions.actionContext(canPlay: false, canOpenInNewWindow: true)
        #expect(
            ItemAction.available(for: book, progress: nil, context: withWindows).map(\.kind) == [
                .markFinished, .openDetails, .openInNewWindow,
            ])
        let withoutWindows = ItemCardActions.actionContext(canPlay: false)
        #expect(
            !ItemAction.available(for: book, progress: nil, context: withoutWindows).contains {
                $0.kind == .openInNewWindow
            })

        // Opening is navigation, which the screens do: the item actions aren't called, nothing fails.
        let actions = RecordingItemActions()
        actions.fails = true
        #expect(await ItemCardActions.perform(.openInNewWindow, on: book, actions: actions, play: nil) == nil)
        #expect(ItemCardActions.failureMessageKey(for: .openInNewWindow) == nil)
        #expect(actions.calls.isEmpty)
    }

    @Test func progressActionsGoToTheItemActions() async {
        let actions = RecordingItemActions()
        let episode = ItemSummary(item: SampleLibrary.episodeItems[0])

        #expect(await ItemCardActions.perform(.markFinished, on: episode, actions: actions, play: nil) == nil)
        #expect(await ItemCardActions.perform(.markNotFinished, on: episode, actions: actions, play: nil) == nil)
        #expect(
            await ItemCardActions.perform(.hideFromContinueListening, on: episode, actions: actions, play: nil) == nil)

        #expect(actions.calls.map(\.0) == [.markFinished, .markNotFinished, .hideFromContinueListening])
        let target = ItemActionTarget(
            libraryItemID: episode.itemID, episodeID: episode.episodeID, duration: episode.duration)
        #expect(actions.calls.allSatisfy { $0.1 == target })
    }

    @Test func failedActionsReportTheirMessage() async {
        let actions = RecordingItemActions()
        actions.fails = true
        let book = ItemSummary(item: SampleLibrary.frankenstein)

        #expect(
            await ItemCardActions.perform(.markFinished, on: book, actions: actions, play: nil)
                == "ToastItemMarkedAsFinishedFailed")
        #expect(
            await ItemCardActions.perform(.markNotFinished, on: book, actions: actions, play: nil)
                == "ToastItemMarkedAsNotFinishedFailed")
        #expect(
            await ItemCardActions.perform(.hideFromContinueListening, on: book, actions: actions, play: nil)
                == "MessageHideFromContinueListeningFailed")
    }

    @Test func playCallsThePlayerWithTheEpisode() async {
        let actions = RecordingItemActions()
        let episode = ItemSummary(item: SampleLibrary.episodeItems[0])
        let played = PlayedItems()
        let play = PlayItemAction { itemID, episodeID, _ in played.items.append((itemID, episodeID)) }
        let failing = PlayItemAction { _, _, _ in throw RecordingItemActions.Failure() }

        #expect(await ItemCardActions.perform(.play, on: episode, actions: actions, play: nil) == nil)
        #expect(await ItemCardActions.perform(.play, on: episode, actions: actions, play: play) == nil)
        #expect(
            await ItemCardActions.perform(.play, on: episode, actions: actions, play: failing)
                == "MessagePlaybackStartFailed")

        #expect(played.items.count == 1)
        #expect(played.items.first?.0 == episode.itemID && played.items.first?.1 == episode.episodeID)
        #expect(actions.calls.isEmpty)
    }
}
