import ABSAPI
import ABSCore
import Foundation
import Observation

/// What ``LibraryBrowseModel``'s list loads: a library and the query for it. A library switch is
/// a query switch, so the list's generation drops late responses of the library left behind.
public struct LibraryBrowseQuery: Sendable, Hashable {
    public var libraryID: String
    public var query: LibraryQuery
    /// The pinned filter can't be queried in the library
    /// (``LibraryBrowseModel/isFilterUnsupported``), so ``query`` lacks it: the list loads an empty
    /// page without a request instead of the whole library.
    public var isFilterUnsupported = false
}

/// The bookshelf of one library at a time: turns ``LibraryViewPreferences`` into a query and
/// loads it page by page through an ``ItemListModel``.
///
/// `Item` is the display value the list retains: the page fetcher maps each `LibraryItem` to it
/// at the page boundary (`map`), so the full server objects aren't kept for thousands of rows and
/// this model doesn't depend on the UI kit.
///
/// ``preferences`` are always the stored ones repaired for the library's type
/// (``LibraryViewPreferences/resolved(for:)``), with the ``pinnedFilter`` in place of the stored
/// filter when one is pinned. Nothing is saved until the user changes something with
/// ``update(_:)``, which saves the whole repaired value through `persist`; opening a library, or
/// switching to a library of another type, never writes.
///
/// A pinned filter (for example a narrator's route) is shown and queried but never saved: the
/// library keeps its stored filter. When the repair for the library's type would drop the pinned
/// filter (``isFilterUnsupported``), the list stays empty and no items are requested, rather than
/// showing the whole library.
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
    /// What to show and query with: the stored preferences repaired for ``mediaType``, with the
    /// ``pinnedFilter`` (as is, even if unsupported) in place of their filter.
    public private(set) var preferences: LibraryViewPreferences
    /// A filter shown and queried instead of the stored one, and never saved. It stays pinned
    /// across ``switchLibrary(id:mediaType:stored:)``.
    public let pinnedFilter: LibraryViewPreferences.Filter?
    public let list: ItemListModel<LibraryBrowseQuery, Item>

    /// The repair for ``mediaType`` (``LibraryViewPreferences/resolved(for:)``) would drop
    /// ``pinnedFilter``: the type doesn't offer its group (for example narrators in a podcast
    /// library), or it has no usable value (for example a narrator without a name). The list then
    /// requests no items and ends empty, so views show no items.
    public var isFilterUnsupported: Bool {
        Self.isUnsupported(pinnedFilter, in: preferences, mediaType: mediaType)
    }

    @ObservationIgnored private let defaults: LibraryViewPreferences
    @ObservationIgnored private let persist: Persist?
    /// The stored preferences repaired for ``mediaType``: what ``update(_:)`` saves.
    @ObservationIgnored private var storedPreferences: LibraryViewPreferences

    public var items: [Item] { list.items }
    public var total: Int? { list.total }
    public var isLoading: Bool { list.isLoading }
    public var error: (any Error)? { list.error }
    public var reachedEnd: Bool { list.reachedEnd }

    /// - Parameters:
    ///   - stored: The library's saved preferences, if any.
    ///   - pinnedFilter: A filter to show and query instead of the stored one, without saving it.
    ///   - defaults: Used when nothing is saved.
    ///   - map: Turns a loaded item into the display value; runs off the main actor.
    ///
    /// Nothing loads until ``load()``.
    public init(
        client: any LibraryService, libraryID: String, mediaType: MediaType, stored: LibraryViewPreferences? = nil,
        pinnedFilter: LibraryViewPreferences.Filter? = nil, defaults: LibraryViewPreferences = LibraryViewPreferences(),
        pageSize: Int = 20, prefetchThreshold: Int = 5, connectionKey: LibraryConnectionKey? = nil,
        persist: Persist? = nil, map: @escaping @Sendable (LibraryItem) -> Item
    ) {
        self.libraryID = libraryID
        self.mediaType = mediaType
        self.pinnedFilter = pinnedFilter
        self.defaults = defaults
        self.persist = persist
        let storedPreferences = (stored ?? defaults).resolved(for: mediaType)
        self.storedPreferences = storedPreferences
        let preferences = Self.pinning(pinnedFilter, to: storedPreferences)
        self.preferences = preferences
        list = ItemListModel(
            query: Self.makeBrowseQuery(
                libraryID: libraryID, mediaType: mediaType, preferences: preferences, pinnedFilter: pinnedFilter),
            pageSize: pageSize, prefetchThreshold: prefetchThreshold, connectionKey: connectionKey
        ) { browse, page, limit in
            // The query lacks the unsupported filter: sending it would list the whole library.
            if browse.isFilterUnsupported { return PagedResults(results: [], total: 0, limit: limit, page: page) }
            var query = browse.query
            query.page = page
            query.limit = limit
            return try await client.items(libraryID: browse.libraryID, query: query).map(map)
        }
    }

    /// Loads the first page (or the next one, if some are loaded). Returns the load.
    @discardableResult
    public func load() -> Task<Void, Never>? { list.loadNextPage() }

    /// Changes the preferences and reloads from the first page. The change applies to
    /// ``preferences`` and the result, repaired, is saved. While a filter is pinned, the stored
    /// filter is saved and a filter change is ignored. Returns the first page's load.
    @discardableResult
    public func update(_ change: (inout LibraryViewPreferences) -> Void) -> Task<Void, Never>? {
        var changed = preferences
        change(&changed)
        if pinnedFilter != nil { changed.filter = storedPreferences.filter }
        storedPreferences = changed.resolved(for: mediaType)
        persist?(libraryID, storedPreferences)
        preferences = Self.pinning(pinnedFilter, to: storedPreferences)
        return list.setQuery(browseQuery)
    }

    /// Shows another library with its saved preferences (or the defaults), repaired for its type,
    /// and the same ``pinnedFilter``. Nothing is saved. A page of the previous library still in
    /// flight is dropped.
    @discardableResult
    public func switchLibrary(
        id: String, mediaType: MediaType, stored: LibraryViewPreferences? = nil
    ) -> Task<Void, Never>? {
        libraryID = id
        self.mediaType = mediaType
        storedPreferences = (stored ?? defaults).resolved(for: mediaType)
        preferences = Self.pinning(pinnedFilter, to: storedPreferences)
        return list.setQuery(browseQuery)
    }

    private var browseQuery: LibraryBrowseQuery {
        Self.makeBrowseQuery(
            libraryID: libraryID, mediaType: mediaType, preferences: preferences, pinnedFilter: pinnedFilter)
    }

    private static func makeBrowseQuery(
        libraryID: String, mediaType: MediaType, preferences: LibraryViewPreferences,
        pinnedFilter: LibraryViewPreferences.Filter?
    ) -> LibraryBrowseQuery {
        LibraryBrowseQuery(
            libraryID: libraryID, query: preferences.query(for: mediaType),
            isFilterUnsupported: isUnsupported(pinnedFilter, in: preferences, mediaType: mediaType))
    }

    /// `preferences` with `pinnedFilter`, if any, in place of their filter.
    private static func pinning(
        _ pinnedFilter: LibraryViewPreferences.Filter?, to preferences: LibraryViewPreferences
    ) -> LibraryViewPreferences {
        guard let pinnedFilter else { return preferences }
        var pinned = preferences
        pinned.filter = pinnedFilter
        return pinned
    }

    /// Whether repairing `preferences`, which hold `pinnedFilter`, for `mediaType` drops or changes
    /// the pin (``LibraryViewPreferences/resolved(for:)``), so their query wouldn't apply it.
    private static func isUnsupported(
        _ pinnedFilter: LibraryViewPreferences.Filter?, in preferences: LibraryViewPreferences, mediaType: MediaType
    ) -> Bool {
        guard let pinnedFilter else { return false }
        return preferences.resolved(for: mediaType).filter != pinnedFilter
    }
}
