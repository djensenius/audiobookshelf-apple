import ABSAPI
import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAppModel

/// A library source with one book library and one podcast library, recording each request.
@MainActor
private final class FakeEntitySource: PlayableEntitySource {
    var connectionID: UUID? = EntityFixtures.connection
    var libraryList = [
        Library(id: "books", name: "Books", mediaType: .book), Library(id: "pods", name: "Pods", mediaType: .podcast),
    ]
    var searchResults: [String: LibrarySearchResults] = [:]
    var shelves: [String: [Shelf]] = [:]
    var items: [String: LibraryItem] = [:]
    var progressByKey: [String: MediaProgress] = [:]
    private(set) var requests: [String] = []
    /// Run after each request is recorded, before it returns: to switch accounts or cancel mid-lookup.
    var afterRequest: (@MainActor (FakeEntitySource) -> Void)?

    func libraries() async throws -> [Library] { libraryList }

    func searchLibrary(id: String, query: String, limit: Int?) async throws -> LibrarySearchResults {
        requests.append("search \(id) \(query) \(limit.map(String.init) ?? "-")")
        afterRequest?(self)
        return searchResults[id] ?? LibrarySearchResults()
    }

    func personalizedShelves(libraryID: String) async throws -> [Shelf] {
        requests.append("shelves \(libraryID)")
        afterRequest?(self)
        return shelves[libraryID] ?? []
    }

    func item(id: String) async throws -> LibraryItem {
        requests.append("item \(id)")
        afterRequest?(self)
        guard let item = items[id] else { throw URLError(.fileDoesNotExist) }
        return item
    }

    func progress(libraryItemID: String, episodeID: String?) -> MediaProgress? {
        progressByKey[MediaProgress.key(libraryItemID: libraryItemID, episodeID: episodeID)]
    }
}

private enum EntityFixtures {
    static let connection = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    static let otherConnection = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!

    static func book(_ id: String, author: String? = "Author", tracks: Int = 1, isMissing: Bool = false) -> LibraryItem
    {
        LibraryItem(
            id: id, libraryId: "books", isMissing: isMissing, mediaType: .book,
            media: .book(
                Book(
                    id: "book-\(id)", metadata: BookMetadata(title: "Title \(id)", authorName: author),
                    tracks: (0..<tracks).map { _ in AudioTrack(duration: 60) }, duration: 60 * Double(tracks))))
    }

    static func episode(_ id: String) -> PodcastEpisode {
        PodcastEpisode(id: id, title: "Episode \(id)", audioFile: AudioFile(ino: "ino-\(id)"))
    }

    /// A podcast with `episodes`, or a search's episode match when `recent` is given.
    static func podcast(_ id: String, episodes: [PodcastEpisode] = [], recent: PodcastEpisode? = nil) -> LibraryItem {
        LibraryItem(
            id: id, libraryId: "pods", mediaType: .podcast,
            media: .podcast(
                Podcast(id: "pod-\(id)", metadata: PodcastMetadata(title: "Show \(id)"), episodes: episodes)),
            recentEpisode: recent)
    }

    static func key(_ item: String, _ episode: String? = nil, on connection: UUID = connection) -> String {
        MediaKey(serverConnectionID: connection, libraryItemId: item, episodeId: episode).rawValue
    }
}

@MainActor
@Suite struct PlayableEntityCatalogTests {
    fileprivate let source = FakeEntitySource()
    var catalog: PlayableEntityCatalog { PlayableEntityCatalog(source: source) }

    // MARK: Records

    @Test func aBookRecordCarriesTheEntityFields() throws {
        let record = try #require(
            PlayableEntityRecord(
                summary: ItemSummary(item: EntityFixtures.book("li_1")), connectionID: EntityFixtures.connection))
        #expect(record.kind == .book)
        #expect(record.id == EntityFixtures.key("li_1"))
        #expect(record.title == "Title li_1")
        #expect(record.subtitle == "Author")
        #expect(record.duration == 60)
    }

    @Test func anEpisodeRecordIsKeyedByItsPodcastAndEpisode() throws {
        let podcast = EntityFixtures.podcast("li_p")
        let record = try #require(
            PlayableEntityRecord(
                summary: ItemSummary(item: podcast, episode: EntityFixtures.episode("ep_1")),
                connectionID: EntityFixtures.connection))
        #expect(record.kind == .episode)
        #expect(record.id == EntityFixtures.key("li_p", "ep_1"))
        #expect(record.title == "Episode ep_1")
        #expect(record.subtitle == "Show li_p")
    }

    @Test func unplayableItemsHaveNoRecord() {
        let summaries = [
            ItemSummary(item: EntityFixtures.podcast("li_p")),
            ItemSummary(item: EntityFixtures.book("li_missing", isMissing: true)),
            ItemSummary(item: EntityFixtures.book("li_ebook", tracks: 0)),
            ItemSummary(id: "series-s", itemID: "li_1", seriesID: "s", kind: .series, title: "Series"),
        ]
        #expect(
            summaries.compactMap { PlayableEntityRecord(summary: $0, connectionID: EntityFixtures.connection) }.isEmpty)
    }

    @Test func identifiersRoundTripThroughMediaKey() throws {
        for (item, episode) in [("li_1", nil), ("li_p", "ep_1")] as [(String, String?)] {
            let id = EntityFixtures.key(item, episode)
            let key = try #require(MediaKey(rawValue: id))
            #expect(
                key == MediaKey(serverConnectionID: EntityFixtures.connection, libraryItemId: item, episodeId: episode))
            #expect(key.rawValue == id)
        }
    }

    // MARK: Search

    @Test func searchMapsEachLibrarysBooksAndEpisodes() async throws {
        source.searchResults = [
            "books": LibrarySearchResults(books: [EntityFixtures.book("li_1"), EntityFixtures.book("li_2")]),
            "pods": LibrarySearchResults(
                podcasts: [EntityFixtures.podcast("li_p")],
                episodes: [EntityFixtures.podcast("li_p", recent: EntityFixtures.episode("ep_1"))]),
        ]

        let records = try await catalog.search("  dune ")

        #expect(
            records.map(\.id) == [
                EntityFixtures.key("li_1"), EntityFixtures.key("li_2"), EntityFixtures.key("li_p", "ep_1"),
            ])
        #expect(source.requests == ["search books dune 10", "search pods dune 10"])
    }

    @Test func searchLeavesOutUnplayableMatchesAndDuplicates() async throws {
        source.libraryList = [Library(id: "books", name: "Books", mediaType: .book)]
        source.searchResults = [
            "books": LibrarySearchResults(books: [
                EntityFixtures.book("li_1"), EntityFixtures.book("li_ebook", tracks: 0), EntityFixtures.book("li_1"),
            ])
        ]
        #expect(try await catalog.search("x").map(\.id) == [EntityFixtures.key("li_1")])
    }

    @Test func blankOrSignedOutSearchAsksNothing() async throws {
        #expect(try await catalog.search("  ").isEmpty)
        source.connectionID = nil
        #expect(try await catalog.search("dune").isEmpty)
        #expect(source.requests.isEmpty)
    }

    // MARK: Suggestions

    @Test func suggestionsAreEachLibrarysContinueListeningShelf() async throws {
        let continueBooks = Shelf(
            id: "continue-listening", label: "Continue Listening", type: .book,
            entities: .libraryItems([EntityFixtures.book("li_1"), EntityFixtures.book("li_done")]))
        let recent = Shelf(
            id: "recently-added", label: "Recently Added", type: .book,
            entities: .libraryItems([EntityFixtures.book("li_new")]))
        let continueEpisodes = Shelf(
            id: "continue-listening", label: "Continue Listening", type: .episode,
            entities: .libraryItems([EntityFixtures.podcast("li_p", recent: EntityFixtures.episode("ep_1"))]))
        source.shelves = ["books": [recent, continueBooks], "pods": [continueEpisodes]]
        source.progressByKey = [
            MediaProgress.key(libraryItemID: "li_done", episodeID: nil): MediaProgress(
                id: "mp", libraryItemId: "li_done", isFinished: true)
        ]

        let records = try await catalog.suggestions()

        #expect(records.map(\.id) == [EntityFixtures.key("li_1"), EntityFixtures.key("li_p", "ep_1")])
    }

    @Test func signedOutHasNoSuggestions() async throws {
        source.connectionID = nil
        #expect(try await catalog.suggestions().isEmpty)
        #expect(source.requests.isEmpty)
    }

    // MARK: Identifiers

    @Test func entitiesForIdentifiersFetchesEachItemOnce() async {
        source.items = [
            "li_1": EntityFixtures.book("li_1"),
            "li_p": EntityFixtures.podcast(
                "li_p", episodes: [EntityFixtures.episode("ep_1"), EntityFixtures.episode("ep_2")]),
        ]

        let records = await catalog.entities(for: [
            EntityFixtures.key("li_p", "ep_2"), EntityFixtures.key("li_1"), EntityFixtures.key("li_p", "ep_1"),
        ])

        #expect(
            records.map(\.id) == [
                EntityFixtures.key("li_p", "ep_2"), EntityFixtures.key("li_1"), EntityFixtures.key("li_p", "ep_1"),
            ])
        #expect(records.map(\.title) == ["Episode ep_2", "Title li_1", "Episode ep_1"])
        #expect(source.requests == ["item li_p", "item li_1"])
    }

    @Test func unknownMalformedAndForeignIdentifiersFindNothing() async {
        source.items = [
            "li_1": EntityFixtures.book("li_1"),
            "li_p": EntityFixtures.podcast("li_p", episodes: [EntityFixtures.episode("ep_1")]),
        ]

        let records = await catalog.entities(for: [
            EntityFixtures.key("li_1", on: EntityFixtures.otherConnection),  // another account's
            "li_1",  // not a MediaKey
            EntityFixtures.key("li_gone"),  // not on the server
            EntityFixtures.key("li_p", "ep_gone"),  // not the podcast's episode
            EntityFixtures.key("li_p"),  // a podcast, not an episode
            EntityFixtures.key("li_1", "ep_1"),  // a book has no episodes
        ])

        #expect(records.isEmpty)
        // The foreign and malformed identifiers ask the server nothing; `li_1` is only fetched for
        // the last, this account's, identifier.
        #expect(source.requests == ["item li_gone", "item li_p", "item li_1"])
    }

    @Test func signedOutFindsNoIdentifiers() async {
        source.items = ["li_1": EntityFixtures.book("li_1")]
        source.connectionID = nil
        #expect(await catalog.entities(for: [EntityFixtures.key("li_1")]).isEmpty)
        #expect(source.requests.isEmpty)
    }

    // MARK: Account changes

    @Test func anAccountSwitchDuringALookupFindsNothing() async {
        // Both accounts have an `li_1` and an `li_2`: after the switch, the source would answer
        // with the other account's items, which must not get this account's identifiers.
        source.items = ["li_1": EntityFixtures.book("li_1"), "li_2": EntityFixtures.book("li_2")]
        source.afterRequest = { $0.connectionID = EntityFixtures.otherConnection }

        let records = await catalog.entities(for: [EntityFixtures.key("li_1"), EntityFixtures.key("li_2")])

        #expect(records.isEmpty)
        #expect(source.requests == ["item li_1"])
    }

    @Test func aCancelledLookupFindsNothing() async {
        source.items = ["li_1": EntityFixtures.book("li_1"), "li_2": EntityFixtures.book("li_2")]
        source.afterRequest = { _ in withUnsafeCurrentTask { $0?.cancel() } }

        let records = await catalog.entities(for: [EntityFixtures.key("li_1"), EntityFixtures.key("li_2")])

        #expect(records.isEmpty)
        #expect(source.requests == ["item li_1"])
    }

    @Test func anAccountSwitchDuringASearchThrows() async {
        source.searchResults = ["books": LibrarySearchResults(books: [EntityFixtures.book("li_1")])]
        source.afterRequest = { $0.connectionID = EntityFixtures.otherConnection }

        await #expect(throws: CancellationError.self) { try await catalog.search("dune") }
        #expect(source.requests == ["search books dune 10"])
    }

    @Test func anAccountSwitchDuringSuggestionsThrows() async {
        source.shelves = [
            "books": [
                Shelf(
                    id: "continue-listening", label: "Continue Listening", type: .book,
                    entities: .libraryItems([EntityFixtures.book("li_1")]))
            ]
        ]
        source.afterRequest = { $0.connectionID = EntityFixtures.otherConnection }

        await #expect(throws: CancellationError.self) { try await catalog.suggestions() }
        #expect(source.requests == ["shelves books"])
    }
}
