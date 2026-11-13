import ABSAPI
import ABSCore
import ABSData
import Foundation

/// A book or podcast episode as the App Intents entities show it (#87): the fields the app's
/// `BookEntity` and `PodcastEpisodeEntity` copy, so the mapping is tested here and the entity
/// types stay thin.
///
/// Its ``id`` is the ``MediaKey`` raw value (`"<connection>|<item>|<episode or empty>"`), the same
/// key downloads and local progress use, so an identifier names one item on one account.
public struct PlayableEntityRecord: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case book
        case episode
    }

    public let key: MediaKey
    public let kind: Kind
    public let title: String
    /// The author for a book, the podcast's title for an episode.
    public let subtitle: String?
    /// Series name and sequence, for example `The Stormlight Archive #2`; books only.
    public let seriesText: String?
    /// Seconds.
    public let duration: TimeInterval?

    /// The entity identifier: ``key``'s raw value.
    public var id: String { key.rawValue }

    /// The record for a playable book or episode of `connectionID`'s account; `nil` for anything
    /// else: a podcast, a collapsed series, an item missing on the server, or a book without audio.
    public init?(summary: ItemSummary, connectionID: UUID) {
        let kind: Kind
        switch summary.kind {
        case .book: kind = .book
        case .episode: kind = .episode
        default: return nil
        }
        guard !summary.isMissing, summary.hasAudio else { return nil }
        guard (kind == .episode) == (summary.episodeID != nil) else { return nil }
        key = MediaKey(serverConnectionID: connectionID, libraryItemId: summary.itemID, episodeId: summary.episodeID)
        self.kind = kind
        title = summary.title
        subtitle = summary.subtitle
        seriesText = summary.seriesText
        duration = summary.duration
    }
}

/// What ``PlayableEntityCatalog`` reads: the signed-in account's library. ``LibraryStoreEntitySource``
/// is the app's; tests pass a fake.
@MainActor
public protocol PlayableEntitySource {
    /// The signed-in account's connection; `nil` while signed out.
    var connectionID: UUID? { get }
    func libraries() async throws -> [Library]
    func searchLibrary(id: String, query: String, limit: Int?) async throws -> LibrarySearchResults
    func personalizedShelves(libraryID: String) async throws -> [Shelf]
    func item(id: String) async throws -> LibraryItem
    /// The cached progress, for Continue Listening's finished and hidden items.
    func progress(libraryItemID: String, episodeID: String?) -> MediaProgress?
}

/// Finds the books and episodes the App Intents entities offer: by identifier, by a server
/// search, and Continue Listening as suggestions. Only the signed-in account's items: an
/// identifier of another account (or of a signed-out one) finds nothing, so Siri can't play an
/// item on the wrong server.
@MainActor
public struct PlayableEntityCatalog {
    /// Matches asked of each library's search, per group (books and episodes).
    public static let searchLimit = 10

    let source: any PlayableEntitySource

    public init(source: any PlayableEntitySource) {
        self.source = source
    }

    /// The signed-in account's books and episodes matching `query`, from each library's server
    /// search: books first, in server order, then episodes. Empty for a blank query or while
    /// signed out.
    public func search(_ query: String) async throws -> [PlayableEntityRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let connectionID = source.connectionID else { return [] }
        var records: [PlayableEntityRecord] = []
        for library in try await source.libraries() {
            let results = try await source.searchLibrary(id: library.id, query: query, limit: Self.searchLimit)
            records += (results.books + results.episodes).compactMap {
                PlayableEntityRecord(summary: ItemSummary(item: $0), connectionID: connectionID)
            }
        }
        return Self.unique(records)
    }

    /// Each library's Continue Listening shelf, as Home shows it (finished and hidden items left
    /// out), in library order. Empty while signed out.
    public func suggestions() async throws -> [PlayableEntityRecord] {
        guard let connectionID = source.connectionID else { return [] }
        var records: [PlayableEntityRecord] = []
        for library in try await source.libraries() {
            let shelves = try await source.personalizedShelves(libraryID: library.id)
            let sections = HomeSection.sections(from: shelves) { source.progress(libraryItemID: $0, episodeID: $1) }
            let shelf = sections.first { $0.id == "continue-listening" }
            records += (shelf?.entries ?? []).compactMap {
                guard case .item(let item) = $0 else { return nil }
                return PlayableEntityRecord(summary: item, connectionID: connectionID)
            }
        }
        return Self.unique(records)
    }

    /// The records for `identifiers`, in their order. An identifier that isn't a ``MediaKey``,
    /// belongs to another account, or names an item or episode the server no longer has (or that
    /// can't be played) is left out.
    public func entities(for identifiers: [String]) async -> [PlayableEntityRecord] {
        guard let connectionID = source.connectionID else { return [] }
        var items: [String: LibraryItem?] = [:]
        var records: [PlayableEntityRecord] = []
        for identifier in identifiers {
            guard let key = MediaKey(rawValue: identifier), key.serverConnectionID == connectionID else { continue }
            let item: LibraryItem?
            if let cached = items[key.libraryItemId] {
                item = cached
            } else {
                item = try? await source.item(id: key.libraryItemId)
                items[key.libraryItemId] = .some(item)
            }
            guard let item, let summary = Self.summary(of: item, episodeID: key.episodeId),
                let record = PlayableEntityRecord(summary: summary, connectionID: connectionID), record.key == key
            else { continue }
            records.append(record)
        }
        return records
    }

    /// The item's summary, or its episode's; `nil` when the episode isn't the podcast's.
    private static func summary(of item: LibraryItem, episodeID: String?) -> ItemSummary? {
        guard let episodeID else { return ItemSummary(item: item) }
        guard case .podcast(let podcast) = item.media,
            let episode = podcast.episodes?.first(where: { $0.id == episodeID })
        else { return nil }
        return ItemSummary(item: item, episode: episode)
    }

    private static func unique(_ records: [PlayableEntityRecord]) -> [PlayableEntityRecord] {
        var seen: Set<String> = []
        return records.filter { seen.insert($0.id).inserted }
    }
}

/// The ``LibraryStore``'s account as a ``PlayableEntitySource``. Requests go through
/// ``LibraryStore/makeServices()``, so they throw `CancellationError` while the store has no
/// client (signed out, or offline) and when the account changes mid-request.
@MainActor
public struct LibraryStoreEntitySource: PlayableEntitySource {
    let store: LibraryStore

    public init(store: LibraryStore) {
        self.store = store
    }

    public var connectionID: UUID? { store.connectionKey?.connectionID }

    /// The store's libraries once loaded; otherwise (an intent that launched the app) the server's.
    public func libraries() async throws -> [Library] {
        if store.hasLoaded { return store.libraries }
        return try await services().libraries()
    }

    public func searchLibrary(id: String, query: String, limit: Int?) async throws -> LibrarySearchResults {
        try await services().searchLibrary(id: id, query: query, limit: limit)
    }

    public func personalizedShelves(libraryID: String) async throws -> [Shelf] {
        try await services().personalizedShelves(libraryID: libraryID)
    }

    public func item(id: String) async throws -> LibraryItem {
        try await services().item(id: id)
    }

    public func progress(libraryItemID: String, episodeID: String?) -> MediaProgress? {
        store.progress.progress(libraryItemID: libraryItemID, episodeID: episodeID)
    }

    private func services() throws -> LibraryStoreServices {
        guard let services = store.makeServices() else { throw CancellationError() }
        return services
    }
}
