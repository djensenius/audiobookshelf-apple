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
    /// Most recent first, de-duplicated ignoring case, at most ``maxRecentSearches``.
    public private(set) var recentSearches: [String]

    /// The running search, including its debounce. Tests await it.
    @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
    @ObservationIgnored private let service: any SearchService
    @ObservationIgnored private let limit: Int?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let persistRecents: PersistRecents?
    @ObservationIgnored private var generation = 0

    /// - Parameters:
    ///   - recentSearches: The library's saved recent searches, cleaned up like new ones.
    ///   - limit: The maximum results per group; `nil` uses the server's default.
    ///   - clock: Times the debounce; tests pass a manual clock.
    public init(
        service: any SearchService, libraryID: String, recentSearches: [String] = [], limit: Int? = nil,
        debounce: Duration = .milliseconds(300), clock: any Clock<Duration> = ContinuousClock(),
        persistRecents: PersistRecents? = nil
    ) {
        self.service = service
        self.libraryID = libraryID
        self.limit = limit
        self.debounce = debounce
        self.clock = clock
        self.persistRecents = persistRecents
        var recents: [String] = []
        for query in recentSearches.map(Self.trimmed) where !query.isEmpty {
            if !recents.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) { recents.append(query) }
        }
        self.recentSearches = Array(recents.prefix(Self.maxRecentSearches))
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

    /// Searches for the current query at once, for example on Return, and remembers it as a
    /// recent search.
    public func submit() {
        let previous = recentSearches
        Self.add(query, to: &recentSearches)
        if recentSearches != previous { persistRecents?(recentSearches) }
        search(after: nil)
    }

    public func clearRecentSearches() {
        guard !recentSearches.isEmpty else { return }
        recentSearches = []
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
