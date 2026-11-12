import ABSAPI
import ABSCore
import Foundation
import Observation

/// A paged list (library items, series, collections, …) that loads pages as the user scrolls.
///
/// Port of the paging in the legacy `LazyBookshelf.vue`. Call ``loadNextPage()`` to load the
/// first page and ``itemAppeared(at:)`` as cells appear; the next page is requested when a cell
/// within ``prefetchThreshold`` of the end appears. Items whose ID was already loaded are
/// skipped, because offset paging repeats items when the list changes on the server.
///
/// Paging counts the rows the server sent (`PagedResults.rawCount`), so rows that fail to
/// decode don't end the list early. A page that adds no item (all its rows malformed or
/// duplicates) can't be scrolled to, so the next page loads right away, until
/// ``maxEmptyPagesInARow`` such pages arrived in a row; then the next page waits for
/// ``loadNextPage()`` or an appearing item, so a server sending only malformed rows can't loop.
///
/// Changing the query with ``setQuery(_:)`` (or calling ``reset()``) cancels the page in flight,
/// clears the list and loads the first page again. ``refresh()`` reloads too, but keeps the list
/// until the first new page replaces it. Each reset or refresh starts a new generation, and a
/// response from an earlier generation is never applied. If the refresh's first page fails or is
/// cancelled, the list rolls back to where it was before the refresh: scrolling continues with the
/// old list's next page, and retrying the refresh means calling ``refresh()`` again.
///
/// A model belongs to one client and account: views create it per account identity (with
/// `LibraryStore.makeItemList(libraryID:query:)`) and recreate it when the store's
/// `connectionKey` no longer matches ``connectionKey``.
@MainActor
@Observable
public final class ItemListModel<Query: Hashable & Sendable, Item: Identifiable & Sendable> {
    /// Fetches one page; `page` is zero-based and `limit` is ``pageSize``.
    public typealias PageFetcher =
        @Sendable (_ query: Query, _ page: Int, _ limit: Int) async throws -> PagedResults<Item>

    public private(set) var query: Query
    public private(set) var items: [Item] = []
    /// The server's total for the query, once a page reported it.
    public private(set) var total: Int?
    public private(set) var isLoading = false
    /// The error of the last page load. Appearing items don't retry; call ``loadNextPage()``.
    public private(set) var error: (any Error)?
    /// Every page has been loaded.
    public private(set) var reachedEnd = false

    /// Items per page; ``setPaging(pageSize:prefetchThreshold:)`` changes it.
    public private(set) var pageSize: Int
    /// How close to the end an appearing item triggers the next page.
    public var prefetchThreshold: Int
    /// The account the model loads for, when created by `LibraryStore`.
    public let connectionKey: LibraryConnectionKey?
    /// How many pages that add no item load automatically in a row.
    public let maxEmptyPagesInARow = 3

    @ObservationIgnored private let fetchPage: PageFetcher
    /// A page size waiting for the list to start over: pages are offsets of `page * limit`, so the
    /// size can't change between pages of one generation.
    @ObservationIgnored private var pendingPageSize: Int?
    @ObservationIgnored private var nextPage = 0
    /// Rows received, including duplicates and rows that failed to decode, compared with
    /// `total` to detect the end.
    @ObservationIgnored private var fetchedCount = 0
    /// Consecutive pages that added no item.
    @ObservationIgnored private var emptyPagesInARow = 0
    @ObservationIgnored private var indexByID: [Item.ID: Int] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Set by ``refresh()`` until its first page lands: the paging state of the items on
    /// screen, restored if that page fails or is cancelled. While set, the next page replaces the
    /// items instead of being appended.
    @ObservationIgnored private var refreshRollback: PagingState?

    private struct PagingState {
        var nextPage: Int
        /// The size of the kept pages: a refresh may have switched to a pending one.
        var pageSize: Int
        var fetchedCount: Int
        var total: Int?
        var reachedEnd: Bool
        var emptyPagesInARow: Int
    }

    /// - Parameters:
    ///   - pageSize: Items per page; `0` asks for everything in one page.
    ///   - prefetchThreshold: How close to the end an appearing item triggers the next page.
    public init(
        query: Query, pageSize: Int = 20, prefetchThreshold: Int = 5, connectionKey: LibraryConnectionKey? = nil,
        fetchPage: @escaping PageFetcher
    ) {
        self.query = query
        self.pageSize = pageSize
        self.prefetchThreshold = prefetchThreshold
        self.connectionKey = connectionKey
        self.fetchPage = fetchPage
    }

    isolated deinit {
        loadTask?.cancel()
    }

    /// Switches to `query` and reloads from the first page; does nothing if it is unchanged.
    /// Returns the first page's load.
    @discardableResult
    public func setQuery(_ query: Query) -> Task<Void, Never>? {
        guard query != self.query else { return nil }
        self.query = query
        return reset()
    }

    /// Cancels the page in flight, clears the list and loads the first page. Returns its load.
    @discardableResult
    public func reset() -> Task<Void, Never>? {
        restart()
        refreshRollback = nil
        items = []
        total = nil
        indexByID = [:]
        return loadNextPage()
    }

    /// Reloads from the first page, for example on pull to refresh. The current items stay until
    /// the first page arrives and replaces them; later pages are appended as usual. Returns the
    /// first page's load.
    @discardableResult
    public func refresh() -> Task<Void, Never>? {
        // A refresh replacing an unfinished one keeps the first snapshot: the items are still
        // the ones it describes.
        if refreshRollback == nil {
            refreshRollback = PagingState(
                nextPage: nextPage, pageSize: pageSize, fetchedCount: fetchedCount, total: total,
                reachedEnd: reachedEnd,
                emptyPagesInARow: emptyPagesInARow)
        }
        restart()
        return loadNextPage()
    }

    /// Changes the paging, for example when a wider window shows more columns. The threshold
    /// applies to the next appearing item. The page size applies right away if no page was
    /// requested yet, and otherwise from the next first page (``reset()``, ``refresh()`` or
    /// ``setQuery(_:)``), as offsets of the loaded pages depend on it.
    public func setPaging(pageSize: Int, prefetchThreshold: Int) {
        self.prefetchThreshold = prefetchThreshold
        if nextPage == 0, loadTask == nil, items.isEmpty, refreshRollback == nil {
            self.pageSize = pageSize
            pendingPageSize = nil
        } else if pageSize != self.pageSize {
            pendingPageSize = pageSize
        } else {
            pendingPageSize = nil
        }
    }

    private func restart() {
        generation += 1
        if let pendingPageSize {
            pageSize = pendingPageSize
            self.pendingPageSize = nil
        }
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        error = nil
        reachedEnd = false
        nextPage = 0
        fetchedCount = 0
        emptyPagesInARow = 0
    }

    /// Loads the next page unless one is in flight or the end was reached. Returns the page's
    /// load (the one already in flight, if any), or `nil` when there is nothing to load.
    @discardableResult
    public func loadNextPage() -> Task<Void, Never>? {
        if let loadTask { return loadTask }
        guard !reachedEnd else { return nil }
        let generation = generation
        let query = query
        let page = nextPage
        let limit = pageSize
        let fetchPage = fetchPage
        isLoading = true
        error = nil
        let task = Task { [weak self] in
            let result: Result<PagedResults<Item>, any Error>
            do {
                result = .success(try await fetchPage(query, page, limit))
            } catch {
                result = .failure(error)
            }
            self?.finish(result, generation: generation)
        }
        loadTask = task
        return task
    }

    /// Call when the item at `index` appears; prefetches the next page near the end.
    public func itemAppeared(at index: Int) {
        guard error == nil, index >= items.count - prefetchThreshold else { return }
        loadNextPage()
    }

    /// Call when the item with `id` appears; prefetches the next page near the end.
    public func itemAppeared(id: Item.ID) {
        guard let index = indexByID[id] else { return }
        itemAppeared(at: index)
    }

    private func finish(_ result: Result<PagedResults<Item>, any Error>, generation: Int) {
        // A reset since the request started owns the state now.
        guard generation == self.generation else { return }
        loadTask = nil
        isLoading = false
        switch result {
        case .success(let page):
            nextPage += 1
            fetchedCount += page.rawCount
            var appended = items
            if refreshRollback != nil {
                refreshRollback = nil
                appended = []
                indexByID = [:]
            }
            var added = 0
            for item in page.results where indexByID[item.id] == nil {
                indexByID[item.id] = appended.count
                appended.append(item)
                added += 1
            }
            items = appended
            total = page.total
            reachedEnd =
                if page.rawCount == 0 || pageSize <= 0 {
                    true
                } else if let total = page.total {
                    fetchedCount >= total
                } else {
                    page.rawCount < pageSize
                }
            emptyPagesInARow = added == 0 ? emptyPagesInARow + 1 : 0
            if !reachedEnd, added == 0, emptyPagesInARow < maxEmptyPagesInARow {
                loadNextPage()
            }
        case .failure(let error):
            // A failed or cancelled refresh keeps the items on screen, so it restores their
            // paging state: the next page continues the old list instead of appending page 0.
            if let rollback = refreshRollback {
                refreshRollback = nil
                nextPage = rollback.nextPage
                // The kept pages are offsets of the old size; the newest requested size waits
                // for the next restart again.
                let requested = pendingPageSize ?? pageSize
                pageSize = rollback.pageSize
                pendingPageSize = requested == pageSize ? nil : requested
                fetchedCount = rollback.fetchedCount
                total = rollback.total
                reachedEnd = rollback.reachedEnd
                emptyPagesInARow = rollback.emptyPagesInARow
            }
            if !(error is CancellationError) { self.error = error }
        }
    }
}

extension ItemListModel where Query == LibraryQuery, Item == LibraryItem {
    /// The items of a library. The query's `page` and `limit` are set by the model.
    public convenience init(
        client: any LibraryService, libraryID: String, query: LibraryQuery = LibraryQuery(), pageSize: Int = 20,
        prefetchThreshold: Int = 5, connectionKey: LibraryConnectionKey? = nil
    ) {
        self.init(
            query: query, pageSize: pageSize, prefetchThreshold: prefetchThreshold, connectionKey: connectionKey
        ) { query, page, limit in
            var query = query
            query.page = page
            query.limit = limit
            return try await client.items(libraryID: libraryID, query: query)
        }
    }
}
