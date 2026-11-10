import ABSAPI
import ABSCore
import Foundation
import Observation

/// The choices of the filter sheet for one library, from its `filterdata`.
///
/// A model belongs to one account (like ``ItemListModel``): create it per ``LibraryConnectionKey``
/// and recreate it when the key changes. It loads a library's filter data once and keeps the
/// choices per library until ``reload()``. Responses for a library the model has since left, or
/// for a load that ``reload()`` replaced, are dropped.
@MainActor
@Observable
public final class LibraryFilterModel {
    /// A value to filter by: `id` goes to `LibraryFilter` (an item ID, or the name itself for
    /// genres, tags, narrators and languages) and `name` is shown.
    public struct Choice: Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
    }

    public struct Choices: Sendable, Hashable {
        public var genres: [Choice] = []
        public var tags: [Choice] = []
        public var series: [Choice] = []
        public var authors: [Choice] = []
        public var narrators: [Choice] = []
        public var languages: [Choice] = []
    }

    /// The fixed progress filter values (the `progress` group's values); views localize the names.
    public enum ProgressState: String, Sendable, CaseIterable {
        case finished
        case inProgress = "in-progress"
        case notStarted = "not-started"
        case notFinished = "not-finished"
    }

    public private(set) var libraryID: String?
    /// The choices of ``libraryID``, once loaded.
    public private(set) var choices: Choices?
    public private(set) var isLoading = false
    /// The error of the last load of ``libraryID``.
    public private(set) var error: (any Error)?
    public let connectionKey: LibraryConnectionKey?

    @ObservationIgnored private let client: any LibraryService
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private var cache: [String: Choices] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    public init(client: any LibraryService, connectionKey: LibraryConnectionKey? = nil, locale: Locale = .current) {
        self.client = client
        self.connectionKey = connectionKey
        self.locale = locale
    }

    isolated deinit {
        loadTask?.cancel()
    }

    /// Shows `libraryID`'s choices: from the cache, or by loading them. Returns the load, or `nil`
    /// when the choices were cached or `libraryID` is already loading.
    @discardableResult
    public func load(libraryID: String) -> Task<Void, Never>? {
        if libraryID == self.libraryID, loadTask != nil { return loadTask }
        switchTo(libraryID)
        if let cached = cache[libraryID] {
            choices = cached
            return nil
        }
        return startLoad(libraryID)
    }

    /// Loads the current library's filter data again, keeping the shown choices until it arrives.
    @discardableResult
    public func reload() -> Task<Void, Never>? {
        guard let libraryID else { return nil }
        cache[libraryID] = nil
        generation += 1
        loadTask?.cancel()
        return startLoad(libraryID)
    }

    private func switchTo(_ libraryID: String) {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        error = nil
        choices = nil
        self.libraryID = libraryID
    }

    private func startLoad(_ libraryID: String) -> Task<Void, Never> {
        let generation = generation
        let client = client
        isLoading = true
        error = nil
        let task = Task { [weak self] in
            let result: Result<LibraryWithFilterData, any Error>
            do {
                result = .success(try await client.library(id: libraryID))
            } catch {
                result = .failure(error)
            }
            self?.finish(result, libraryID: libraryID, generation: generation)
        }
        loadTask = task
        return task
    }

    private func finish(_ result: Result<LibraryWithFilterData, any Error>, libraryID: String, generation: Int) {
        guard generation == self.generation else { return }
        loadTask = nil
        isLoading = false
        switch result {
        case .success(let loaded):
            let mapped = makeChoices(loaded.filterData)
            cache[libraryID] = mapped
            choices = mapped
        case .failure(let error):
            if !(error is CancellationError) { self.error = error }
        }
    }

    private func makeChoices(_ data: LibraryFilterData) -> Choices {
        func named(_ names: [String]) -> [Choice] { sorted(names.map { Choice(id: $0, name: $0) }) }
        return Choices(
            genres: named(data.genres), tags: named(data.tags),
            series: sorted(data.series.map { Choice(id: $0.id, name: $0.name) }),
            authors: sorted(data.authors.map { Choice(id: $0.id, name: $0.name) }),
            narrators: named(data.narrators), languages: named(data.languages))
    }

    /// By name in the locale's collation (case-insensitive, digits by value), then by ID.
    private func sorted(_ choices: [Choice]) -> [Choice] {
        choices.sorted { lhs, rhs in
            switch lhs.name.compare(rhs.name, options: [.caseInsensitive, .numeric], range: nil, locale: locale) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.id < rhs.id
            }
        }
    }
}
