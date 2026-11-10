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
/// Changing the query with ``setQuery(_:)`` (or calling ``reset()``) cancels the page in flight,
/// clears the list and loads the first page again. Each reset starts a new generation, and a
/// response from an earlier generation is never applied.
@MainActor
@Observable
public final class ItemListModel<Query: Hashable & Sendable, Item: Identifiable & Decodable & Sendable> {
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

    public let pageSize: Int
    public let prefetchThreshold: Int

    @ObservationIgnored private let fetchPage: PageFetcher
    @ObservationIgnored private var nextPage = 0
    /// Results received, including duplicates, compared with `total` to detect the end.
    @ObservationIgnored private var fetchedCount = 0
    @ObservationIgnored private var indexByID: [Item.ID: Int] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// - Parameters:
    ///   - pageSize: Items per page; `0` asks for everything in one page.
    ///   - prefetchThreshold: How close to the end an appearing item triggers the next page.
    public init(query: Query, pageSize: Int = 20, prefetchThreshold: Int = 5, fetchPage: @escaping PageFetcher) {
        self.query = query
        self.pageSize = pageSize
        self.prefetchThreshold = prefetchThreshold
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
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        items = []
        total = nil
        isLoading = false
        error = nil
        reachedEnd = false
        nextPage = 0
        fetchedCount = 0
        indexByID = [:]
        return loadNextPage()
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
            fetchedCount += page.results.count
            var appended = items
            for item in page.results where indexByID[item.id] == nil {
                indexByID[item.id] = appended.count
                appended.append(item)
            }
            items = appended
            total = page.total
            reachedEnd =
                if page.results.isEmpty || pageSize <= 0 {
                    true
                } else if let total = page.total {
                    fetchedCount >= total
                } else {
                    page.results.count < pageSize
                }
        case .failure(let error):
            if !(error is CancellationError) { self.error = error }
        }
    }
}

extension ItemListModel where Query == LibraryQuery, Item == LibraryItem {
    /// The items of a library. The query's `page` and `limit` are set by the model.
    public convenience init(
        client: any LibraryService, libraryID: String, query: LibraryQuery = LibraryQuery(), pageSize: Int = 20,
        prefetchThreshold: Int = 5
    ) {
        self.init(query: query, pageSize: pageSize, prefetchThreshold: prefetchThreshold) { query, page, limit in
            var query = query
            query.page = page
            query.limit = limit
            return try await client.items(libraryID: libraryID, query: query)
        }
    }
}
