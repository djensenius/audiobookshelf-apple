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

@MainActor
@Suite struct HomeScreenStateTests {
    private func resolve(
        hasStore: Bool = true, libraryID: String? = "lib_1", hasLoaded: Bool = false, isLoading: Bool = false,
        hasError: Bool = false, isEmpty: Bool = true
    ) -> HomeScreenState {
        HomeScreenState.resolve(
            hasStore: hasStore, libraryID: libraryID, hasLoaded: hasLoaded, isLoading: isLoading, hasError: hasError,
            isEmpty: isEmpty)
    }

    @Test func withoutAStoreHomeIsSignedOut() {
        #expect(resolve(hasStore: false, hasLoaded: true, isEmpty: false) == .signedOut)
    }

    @Test func withoutALibraryHomeIsEmpty() {
        #expect(resolve(libraryID: nil) == .empty)
    }

    @Test func firstLoadShowsLoadingThenItsError() {
        #expect(resolve() == .loading)
        #expect(resolve(isLoading: true) == .loading)
        #expect(resolve(isLoading: true, hasError: true) == .loading)
        #expect(resolve(hasError: true) == .failed)
    }

    @Test func loadedShelvesStayWhenAReloadFails() {
        #expect(resolve(hasLoaded: true, isEmpty: false) == .shelves(refreshFailed: false))
        #expect(resolve(hasLoaded: true, hasError: true, isEmpty: false) == .shelves(refreshFailed: true))
    }

    @Test func loadedWithoutSectionsIsEmptyUnlessTheReloadFailed() {
        #expect(resolve(hasLoaded: true) == .empty)
        #expect(resolve(hasLoaded: true, hasError: true) == .failed)
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
            for: book, progress: progress, context: HomePresentation.actionContext(canPlay: true)
        )
        .map(\.kind)
        let withoutPlayer = ItemAction.available(
            for: book, progress: progress, context: HomePresentation.actionContext(canPlay: false)
        )
        .map(\.kind)

        #expect(withPlayer == [.play, .markFinished, .hideFromContinueListening, .openDetails])
        #expect(withoutPlayer == [.markFinished, .hideFromContinueListening, .openDetails])
    }

    @Test func progressActionsGoToTheItemActions() async {
        let actions = RecordingItemActions()
        let episode = ItemSummary(item: SampleLibrary.episodeItems[0])

        #expect(await HomePresentation.perform(.markFinished, on: episode, actions: actions, play: nil) == nil)
        #expect(
            await HomePresentation.perform(.hideFromContinueListening, on: episode, actions: actions, play: nil) == nil)

        #expect(actions.calls.map(\.0) == [.markFinished, .hideFromContinueListening])
        let target = ItemActionTarget(
            libraryItemID: episode.itemID, episodeID: episode.episodeID, duration: episode.duration)
        #expect(actions.calls.allSatisfy { $0.1 == target })
    }

    @Test func failedActionsReportTheirMessage() async {
        let actions = RecordingItemActions()
        actions.fails = true
        let book = ItemSummary(item: SampleLibrary.frankenstein)

        #expect(
            await HomePresentation.perform(.markFinished, on: book, actions: actions, play: nil)
                == "ToastItemMarkedAsFinishedFailed")
        #expect(
            await HomePresentation.perform(.hideFromContinueListening, on: book, actions: actions, play: nil)
                == "MessageHideFromContinueListeningFailed")
    }

    @Test func playCallsThePlayerWithTheEpisode() async {
        let actions = RecordingItemActions()
        let episode = ItemSummary(item: SampleLibrary.episodeItems[0])
        let played = PlayedItems()
        let play = PlayItemAction { itemID, episodeID, _ in played.items.append((itemID, episodeID)) }
        let failing = PlayItemAction { _, _, _ in throw RecordingItemActions.Failure() }

        #expect(await HomePresentation.perform(.play, on: episode, actions: actions, play: nil) == nil)
        #expect(await HomePresentation.perform(.play, on: episode, actions: actions, play: play) == nil)
        #expect(
            await HomePresentation.perform(.play, on: episode, actions: actions, play: failing)
                == "MessagePlaybackStartFailed")

        #expect(played.items.count == 1)
        #expect(played.items.first?.0 == episode.itemID && played.items.first?.1 == episode.episodeID)
        #expect(actions.calls.isEmpty)
    }
}
