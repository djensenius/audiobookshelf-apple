import ABSAPI
import ABSCore
import Foundation
import Observation

/// The search screen's state for one library: the query, its results as
/// ``SearchResultGroups``, and the recent searches. A port of the legacy `pages/search.vue`.
///
/// A model belongs to one library and account; views recreate it when either changes, like
/// ``HomeModel``.
///
/// Typing calls ``setQuery(_:)``, which searches after ``debounce`` without further typing;
/// ``submit()`` searches at once and remembers the query. Starting a search cancels the previous
/// one, and a response to a search that isn't the latest is dropped.
@MainActor
@Observable
public final class SearchModel {
    /// Saves the recent searches after they changed.
    public typealias PersistRecents = @MainActor (_ recentSearches: [String]) -> Void
    /// Reads the saved recent searches. Observable storage (such as `AppSettings`) makes views
    /// showing ``recentSearches`` update when another window or a reset changes them.
    public typealias LoadRecents = @MainActor () -> [String]

    /// How many recent searches are kept.
    public static let maxRecentSearches = 10

    public let libraryID: String
    /// The text as typed.
    public private(set) var query = ""
    /// The results of ``searchedQuery``; empty before the first search and for a blank query.
    public private(set) var results = SearchResultGroups.empty
    /// The trimmed query ``results`` belong to; `nil` when nothing was searched.
    public private(set) var searchedQuery: String?
    /// A request is running. `false` while the debounce waits.
    public private(set) var isSearching = false
    /// The error of the last search, cleared by the next successful one or a blank query. The
    /// previous ``results`` stay.
    public private(set) var error: (any Error)?
    /// Most recent first, de-duplicated ignoring case, at most ``maxRecentSearches``. With
    /// `loadRecents`, always the saved list, so a clear or reset elsewhere shows here too.
    public var recentSearches: [String] {
        loadRecents.map { Self.cleaned($0()) } ?? savedRecents
    }

    /// The running search, including its debounce. Tests await it.
    @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
    @ObservationIgnored private let service: any SearchService
    @ObservationIgnored private let limit: Int?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let persistRecents: PersistRecents?
    @ObservationIgnored private let loadRecents: LoadRecents?
    /// The recent searches without `loadRecents`.
    private var savedRecents: [String]
    @ObservationIgnored private var generation = 0

    /// - Parameters:
    ///   - recentSearches: The library's saved recent searches, cleaned up like new ones. Ignored
    ///     with `loadRecents`.
    ///   - limit: The maximum results per group; `nil` uses the server's default.
    ///   - clock: Times the debounce; tests pass a manual clock.
    ///   - persistRecents: Saves the recent searches after ``submit()`` or a clear changed them.
    ///   - loadRecents: Reads the saved recent searches. When set, the saved list is the only
    ///     copy: ``recentSearches`` reads it, and ``submit()`` and ``clearRecentSearches()`` change
    ///     what is saved now, so several models of one library (one per window) don't restore
    ///     each other's cleared searches.
    public init(
        service: any SearchService, libraryID: String, recentSearches: [String] = [], limit: Int? = nil,
        debounce: Duration = .milliseconds(300), clock: any Clock<Duration> = ContinuousClock(),
        persistRecents: PersistRecents? = nil, loadRecents: LoadRecents? = nil
    ) {
        self.service = service
        self.libraryID = libraryID
        self.limit = limit
        self.debounce = debounce
        self.clock = clock
        self.persistRecents = persistRecents
        self.loadRecents = loadRecents
        self.savedRecents = loadRecents == nil ? Self.cleaned(recentSearches) : []
    }

    isolated deinit {
        searchTask?.cancel()
    }

    /// Sets the query as the user types and searches once it hasn't changed for ``debounce``.
    /// A blank query clears the results at once, without a request. Setting the same text again
    /// does nothing, so a binding that re-sets it doesn't cancel the running search.
    public func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        search(after: debounce)
    }

    /// Searches for the current query at once, without remembering it as a recent search: for a
    /// search the user didn't submit, such as a query carried to another library or a retry.
    public func searchNow() {
        search(after: nil)
    }

    /// Searches for the current query at once, for example on Return, and remembers it as a
    /// recent search. Only explicit submissions should record one.
    public func submit() {
        let previous = recentSearches
        var recents = previous
        Self.add(query, to: &recents)
        if recents != previous {
            savedRecents = recents
            persistRecents?(recents)
        }
        search(after: nil)
    }

    public func clearRecentSearches() {
        guard !recentSearches.isEmpty else { return }
        savedRecents = []
        persistRecents?([])
    }

    /// Cancels the running search and starts one for ``query``, after `delay` if set.
    private func search(after delay: Duration?) {
        searchTask?.cancel()
        searchTask = nil
        generation += 1
        isSearching = false
        let term = Self.trimmed(query)
        guard !term.isEmpty else {
            results = .empty
            searchedQuery = nil
            error = nil
            return
        }
        let generation = generation
        let (service, clock, libraryID, limit) = (service, clock, libraryID, limit)
        searchTask = Task { [weak self] in
            if let delay {
                do { try await clock.sleep(for: delay) } catch { return }
            }
            // The model may be gone (its deinit cancels this task) or a newer search started.
            guard self != nil, !Task.isCancelled else { return }
            self?.isSearching = true
            let result: Result<LibrarySearchResults, any Error>
            do {
                result = .success(try await service.searchLibrary(id: libraryID, query: term, limit: limit))
            } catch {
                result = .failure(error)
            }
            self?.apply(result, for: term, generation: generation)
        }
    }

    private func apply(_ result: Result<LibrarySearchResults, any Error>, for term: String, generation: Int) {
        guard generation == self.generation else { return }
        isSearching = false
        switch result {
        case .success(let response):
            results = SearchResultGroups(response)
            searchedQuery = term
            error = nil
        case .failure(let error):
            if !(error is CancellationError) { self.error = error }
        }
    }

    /// Trimmed, without blanks or case-insensitive duplicates, at most ``maxRecentSearches``.
    private static func cleaned(_ queries: [String]) -> [String] {
        var recents: [String] = []
        for query in queries.map(trimmed) where !query.isEmpty {
            if !recents.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) { recents.append(query) }
        }
        return Array(recents.prefix(maxRecentSearches))
    }

    /// Moves `query` to the front of `recents`, replacing a match that differs only in case.
    private static func add(_ query: String, to recents: inout [String]) {
        let term = trimmed(query)
        guard !term.isEmpty else { return }
        recents.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
        recents.insert(term, at: 0)
        if recents.count > maxRecentSearches { recents.removeLast(recents.count - maxRecentSearches) }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
