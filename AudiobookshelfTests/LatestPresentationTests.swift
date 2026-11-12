import ABSAPI
import ABSAppModel
import ABSCore
import ABSUI
import Foundation
import Synchronization
import Testing

@testable import Audiobookshelf

private struct Failure: Error {}

/// A library client serving one page of `episodes` for every library, recording the requests, and failing them
/// while `fails` is set.
private final class FakeLatestClient: LibraryService, LatestEpisodesService {
    let episodes: [RecentEpisode]
    let fails = Mutex(false)
    let requests = Mutex<[String]>([])

    init(episodes: [RecentEpisode]) {
        self.episodes = episodes
    }

    func libraries() async throws -> [Library] { [] }
    func library(id: String) async throws -> LibraryWithFilterData { throw Failure() }
    func personalizedShelves(libraryID: String) async throws -> [Shelf] { [] }
    func items(libraryID: String, query: LibraryQuery) async throws -> PagedResults<LibraryItem> { throw Failure() }

    func recentEpisodes(libraryID: String, page: Int, limit: Int) async throws -> RecentEpisodesPage {
        requests.withLock { $0.append("\(libraryID)#\(page)") }
        if fails.withLock({ $0 }) { throw Failure() }
        return RecentEpisodesPage(episodes: page == 0 ? episodes : [], limit: limit, page: page)
    }
}

private func recent(_ id: String, explicit: Bool = false) -> RecentEpisode {
    RecentEpisode(
        episode: PodcastEpisode(id: id, libraryItemId: "li_pod", title: "Episode \(id)", duration: 60),
        podcast: Podcast(id: "pod", metadata: PodcastMetadata(title: "Classic Tales", explicit: explicit)))
}

@MainActor
@Suite struct LatestPresentationTests {
    private let english = Locale(identifier: "en_US")

    @Test func messagesAreLocalized() {
        let messages = LatestPresentation.messages
        for key in [messages.failed, messages.empty] {
            #expect(L10n.string(key) != key, "\(key)")
        }
        #expect(messages.failed != messages.empty)
    }

    @Test func publishedTextIsRelativeToNow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let twoDaysAgo = Int(now.addingTimeInterval(-2 * 86_400).timeIntervalSince1970) * 1_000
        #expect(LatestPresentation.publishedText(twoDaysAgo, now: now, locale: english) == "2 days ago")
        #expect(LatestPresentation.publishedText(nil, now: now, locale: english) == nil)
        #expect(LatestPresentation.publishedText(0, now: now, locale: english) == nil)
    }

    /// The text follows `now`, so the list's minute timeline moves it on: a day's boundary, then the next.
    @Test func publishedTextMovesOnAcrossADayBoundary() {
        let published = Date(timeIntervalSince1970: 1_700_000_000)
        let publishedAt = Int(published.timeIntervalSince1970) * 1_000
        func text(hoursLater hours: Double, minutes: Double) -> String? {
            let now = published.addingTimeInterval(hours * 3_600 + minutes * 60)
            return LatestPresentation.publishedText(publishedAt, now: now, locale: english)
        }
        #expect(text(hoursLater: 23, minutes: 59) == "23 hours ago")
        #expect(text(hoursLater: 24, minutes: 1) == "yesterday")
        #expect(text(hoursLater: 47, minutes: 59) == "yesterday")
        #expect(text(hoursLater: 48, minutes: 1) == "2 days ago")
    }

    @Test func detailsValueReadsThePodcastThenTheEpisodesDetails() throws {
        let row = try #require(LatestEpisode(recent("e1", explicit: true)))
        let value = LatestPresentation.detailsValue(
            row, published: "2 days ago", badges: ["Episode 3", "Bonus"], spokenSummary: "A story.")
        #expect(value == "Classic Tales, \(L10n.string("LabelExplicit")), 2 days ago, Episode 3, Bonus, A story.")

        let plain = try #require(LatestEpisode(recent("e2")))
        #expect(
            LatestPresentation.detailsValue(plain, published: nil, badges: [], spokenSummary: nil) == "Classic Tales")
    }

    @Test func theModelLoadsTheKeysLibraryAndResolvesItsStates() async throws {
        let suite = "LatestPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(settings: AppSettings(defaults: defaults))
        #expect(BrowseScreenState.placeholder(store: store, libraryID: "lib_a") == .signedOut)

        let client = FakeLatestClient(episodes: [recent("e1"), recent("e2")])
        let connection = LibraryConnectionKey(connectionID: UUID(), userID: "user")
        await store.connect(client: client, connectionKey: connection)
        let key = try #require(BrowseModelKey(store: store, libraryID: "lib_a"))
        let services = try #require(store.makeServices())
        let model = LatestPresentation.makeModel(key: key, services: services, progress: store.progress)
        #expect(model.list.connectionKey == connection)
        #expect(BrowseScreenState.resolve(list: model.list) == .loading)

        await model.list.loadNextPage()?.value
        #expect(client.requests.withLock { $0 } == ["lib_a#0"])
        #expect(model.list.items.map(\.id) == ["li_pod-e1", "li_pod-e2"])
        #expect(model.list.reachedEnd)
        #expect(BrowseScreenState.resolve(list: model.list) == .loaded(failed: false))

        // A failed refresh keeps the rows and says so.
        client.fails.withLock { $0 = true }
        #expect(await BrowsePresentation.refresh(model.list))
        #expect(BrowseScreenState.resolve(list: model.list) == .loaded(failed: true))

        // A first page that failed offers Retry, which loads it.
        let other = LatestPresentation.makeModel(
            key: try #require(BrowseModelKey(store: store, libraryID: "lib_b")), services: services,
            progress: store.progress)
        await other.list.loadNextPage()?.value
        #expect(BrowseScreenState.resolve(list: other.list) == .failed)
        client.fails.withLock { $0 = false }
        await BrowsePresentation.retry(other.list)?.value
        #expect(Array(client.requests.withLock { $0 }.suffix(2)) == ["lib_b#0", "lib_b#0"])
        #expect(BrowseScreenState.resolve(list: other.list) == .loaded(failed: false))
    }

    @Test func aLibraryWithoutEpisodesIsEmpty() async throws {
        let suite = "LatestPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(settings: AppSettings(defaults: defaults))
        await store.connect(
            client: FakeLatestClient(episodes: []),
            connectionKey: LibraryConnectionKey(connectionID: UUID(), userID: "u"))
        let key = try #require(BrowseModelKey(store: store, libraryID: "lib_a"))
        let model = LatestPresentation.makeModel(
            key: key, services: try #require(store.makeServices()), progress: store.progress)
        await model.list.loadNextPage()?.value
        #expect(BrowseScreenState.resolve(list: model.list) == .empty)
    }
}
