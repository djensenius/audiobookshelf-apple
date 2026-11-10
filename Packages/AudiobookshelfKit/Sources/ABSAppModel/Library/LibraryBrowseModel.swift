import ABSAPI
import ABSCore
import Foundation
import Observation

/// What ``LibraryBrowseModel``'s list loads: a library and the query for it. A library switch is
/// a query switch, so the list's generation drops late responses of the library left behind.
public struct LibraryBrowseQuery: Sendable, Hashable {
    public var libraryID: String
    public var query: LibraryQuery
}

/// The bookshelf of one library at a time: turns ``LibraryViewPreferences`` into a query and
/// loads it page by page through an ``ItemListModel``.
///
/// `Item` is the display value the list retains: the page fetcher maps each `LibraryItem` to it
/// at the page boundary (`map`), so the full server objects aren't kept for thousands of rows and
/// this model doesn't depend on the UI kit.
///
/// ``preferences`` are always the stored ones repaired for the library's type
/// (``LibraryViewPreferences/resolved(for:)``). Nothing is saved until the user changes
/// something with ``update(_:)``, which saves the whole repaired value through `persist`; opening
/// a library, or switching to a library of another type, never writes.
///
/// Changing the preferences or the library starts a new query on the list, which cancels the page
/// in flight and drops a response that arrives after (``ItemListModel``'s generation).
@MainActor
@Observable
public final class LibraryBrowseModel<Item: Identifiable & Sendable> {
    /// Saves a library's preferences after the user changed them.
    public typealias Persist = @MainActor (_ libraryID: String, _ preferences: LibraryViewPreferences) -> Void

    public private(set) var libraryID: String
    public private(set) var mediaType: MediaType
    /// What to show and query with, repaired for ``mediaType``.
    public private(set) var preferences: LibraryViewPreferences
    public let list: ItemListModel<LibraryBrowseQuery, Item>

    @ObservationIgnored private let defaults: LibraryViewPreferences
    @ObservationIgnored private let persist: Persist?

    public var items: [Item] { list.items }
    public var total: Int? { list.total }
    public var isLoading: Bool { list.isLoading }
    public var error: (any Error)? { list.error }
    public var reachedEnd: Bool { list.reachedEnd }

    /// - Parameters:
    ///   - stored: The library's saved preferences, if any.
    ///   - defaults: Used when nothing is saved (``LibraryViewPreferences/defaults(enableAltView:)``).
    ///   - map: Turns a loaded item into the display value; runs off the main actor.
    ///
    /// Nothing loads until ``load()``.
    public init(
        client: any LibraryService, libraryID: String, mediaType: MediaType, stored: LibraryViewPreferences? = nil,
        defaults: LibraryViewPreferences = LibraryViewPreferences(), pageSize: Int = 20, prefetchThreshold: Int = 5,
        connectionKey: LibraryConnectionKey? = nil, persist: Persist? = nil,
        map: @escaping @Sendable (LibraryItem) -> Item
    ) {
        self.libraryID = libraryID
        self.mediaType = mediaType
        self.defaults = defaults
        self.persist = persist
        let preferences = (stored ?? defaults).resolved(for: mediaType)
        self.preferences = preferences
        list = ItemListModel(
            query: LibraryBrowseQuery(libraryID: libraryID, query: preferences.query(for: mediaType)),
            pageSize: pageSize, prefetchThreshold: prefetchThreshold, connectionKey: connectionKey
        ) { browse, page, limit in
            var query = browse.query
            query.page = page
            query.limit = limit
            return try await client.items(libraryID: browse.libraryID, query: query).map(map)
        }
    }

    /// Loads the first page (or the next one, if some are loaded). Returns the load.
    @discardableResult
    public func load() -> Task<Void, Never>? { list.loadNextPage() }

    /// Changes the preferences and reloads from the first page. The change applies to the
    /// repaired preferences and the result is saved. Returns the first page's load.
    @discardableResult
    public func update(_ change: (inout LibraryViewPreferences) -> Void) -> Task<Void, Never>? {
        var changed = preferences
        change(&changed)
        preferences = changed.resolved(for: mediaType)
        persist?(libraryID, preferences)
        return list.setQuery(browseQuery)
    }

    /// Shows another library with its saved preferences (or the defaults), repaired for its type.
    /// Nothing is saved. A page of the previous library still in flight is dropped.
    @discardableResult
    public func switchLibrary(
        id: String, mediaType: MediaType, stored: LibraryViewPreferences? = nil
    ) -> Task<Void, Never>? {
        libraryID = id
        self.mediaType = mediaType
        preferences = (stored ?? defaults).resolved(for: mediaType)
        return list.setQuery(browseQuery)
    }

    private var browseQuery: LibraryBrowseQuery {
        LibraryBrowseQuery(libraryID: libraryID, query: preferences.query(for: mediaType))
    }
}
